;;; genie-rpc.el --- Async RPC to AI coding-agent CLIs (ACP and JSONL) -*- lexical-binding: t; -*-

;; Copyright 2026 Sergei Belousov

;; Author: Sergei Belousov <sergei.o.belousov@gmail.com>
;; Maintainer: Sergei Belousov <sergei.o.belousov@gmail.com>
;; Version: 0.3.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: processes, tools
;; URL: https://github.com/bes-dev/genie.el

;; This file is not part of GNU Emacs.

;; Licensed under the Apache License, Version 2.0 (the "License");
;; you may not use this file except in compliance with the License.
;; You may obtain a copy of the License at
;;
;;     http://www.apache.org/licenses/LICENSE-2.0
;;
;; Unless required by applicable law or agreed to in writing, software
;; distributed under the License is distributed on an "AS IS" BASIS,
;; WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
;; implied.  See the License for the specific language governing
;; permissions and limitations under the License.

;;; Commentary:

;; Application-agnostic plumbing for driving AI coding agents over stdio.
;; A session normalizes each backend's wire protocol into a small set of
;; handler callbacks, so an application never blocks the single-threaded
;; UI and never parses agent-specific JSON itself.
;;
;; Two backends ship with the library, registered in `genie-rpc-backends':
;;
;; - `elmee' — the elmee agent microkernel serving the standard
;;             Agent Client Protocol (`elmee --acp'): one warm JSON-RPC 2.0
;;             server process, sessions opened with `session/new', turns
;;             driven by `session/prompt' and streamed as `session/update'
;;             notifications.
;; - `pi'    — the Pi coding agent (`pi --mode rpc'): a line-delimited
;;             JSON protocol of Pi's own, one persistent process.
;;
;; Adding a backend is adding an entry to `genie-rpc-backends': a prompt
;; sender, an event dispatcher and optional handshake/abort hooks.  No
;; other code in this file is backend-specific.
;;
;; Typical use:
;;
;;   (setq rpc (genie-rpc-open 'elmee (list "elmee" "--acp")
;;                             :directory "~/project/"
;;                             :on-text (lambda (delta) ...)
;;                             :on-done (lambda (answer) ...)))
;;   (genie-rpc-prompt rpc "Refactor foo.el")
;;
;; The process starts lazily on the first prompt; `genie-rpc-abort'
;; interrupts a turn, `genie-rpc-close' ends the session.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(cl-defstruct (genie-rpc-session (:constructor genie-rpc--session) (:copier nil))
  "A live (or lazily started) RPC connection to a coding agent."
  backend command directory proc (acc "") spent handlers stderr
  (next-id 0) pending session-id queue)

(defvar genie-rpc-backends
  '((elmee :persistent t
           :hello genie-rpc--acp-hello
           :prompt genie-rpc--acp-prompt
           :abort genie-rpc--acp-abort
           :dispatch genie-rpc--acp-dispatch)
    (pi :persistent t
        :prompt genie-rpc--pi-prompt
        :abort genie-rpc--pi-abort
        :dispatch genie-rpc--pi-dispatch))
  "Registry of agent backends, keyed by symbol.
Each entry is (NAME . PLIST) with:
  :persistent  non-nil when one process serves many prompts; nil when
               the agent runs one task per process and must be respawned
  :hello       optional function (SESSION) run right after the process
               starts, for protocols with a handshake
  :prompt      function (SESSION TEXT) sending TEXT as the next turn
  :abort       optional function (SESSION) interrupting the turn in
               flight; without one the process is ended instead
  :dispatch    function (SESSION MESSAGE) translating one parsed wire
               message into `genie-rpc--fire' handler calls.")

;;;; Session lifecycle

(defun genie-rpc-open (backend command &rest opts)
  "Create a session for BACKEND, running COMMAND (an argv list).
The process starts lazily on the first `genie-rpc-prompt'.  OPTS is a
plist: `:directory' sets the working directory, and the handler keys
`:on-text' (answer text delta), `:on-tool' (a starting tool's label),
`:on-done' (final answer string or nil), `:on-fail' (error message) and
`:on-exit' (no arguments, the process died) attach callbacks."
  (unless (assq backend genie-rpc-backends)
    (error "Unknown genie-rpc backend: %s" backend))
  (genie-rpc--session :backend backend :command command
                      :directory (or (plist-get opts :directory)
                                     default-directory)
                      :handlers opts))

(defun genie-rpc-live-p (rpc)
  "Return non-nil when session RPC has a live agent process."
  (and rpc
       (genie-rpc-session-proc rpc)
       (process-live-p (genie-rpc-session-proc rpc))))

(defun genie-rpc-prompt (rpc text)
  "Send TEXT as the next user prompt on session RPC.
Starts the agent process (and runs the backend's handshake) when
needed; a spent one-task-per-process agent is replaced by a fresh one."
  (genie-rpc--ensure rpc)
  (funcall (genie-rpc--spec rpc :prompt) rpc text)
  (unless (genie-rpc--spec rpc :persistent)
    (setf (genie-rpc-session-spent rpc) t)))

(defun genie-rpc-abort (rpc)
  "Interrupt the turn in flight on session RPC.
When the backend has no abort hook, ending the process is the abort."
  (when (genie-rpc-live-p rpc)
    (if-let* ((abort (genie-rpc--spec rpc :abort)))
        (funcall abort rpc)
      (genie-rpc-close rpc))))

(defun genie-rpc-close (rpc)
  "End the agent process of session RPC."
  (when (genie-rpc-live-p rpc)
    (delete-process (genie-rpc-session-proc rpc))))

(defun genie-rpc-stderr (rpc &optional lines)
  "Return the last LINES (default 10) of RPC's agent stderr, or nil.
The stderr of the agent process is collected separately from the wire
stream, so a startup failure has a readable reason."
  (when-let* ((buf (and rpc (genie-rpc-session-stderr rpc))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (save-excursion
          (goto-char (point-max))
          (forward-line (- (or lines 10)))
          (let ((tail (string-trim
                       (buffer-substring-no-properties (point) (point-max)))))
            (unless (string-empty-p tail) tail)))))))

;;;; Internals

(defun genie-rpc--spec (rpc key)
  "Value of KEY in the backend spec of session RPC."
  (plist-get (cdr (assq (genie-rpc-session-backend rpc) genie-rpc-backends))
             key))

(defun genie-rpc--fire (rpc key &rest args)
  "Call the KEY handler of session RPC with ARGS, when one is attached."
  (when-let* ((fn (plist-get (genie-rpc-session-handlers rpc) key)))
    (apply fn args)))

(defun genie-rpc--ensure (rpc)
  "Start (or restart) the agent process of session RPC when needed."
  (when (and (genie-rpc-live-p rpc)
             (not (genie-rpc--spec rpc :persistent))
             (genie-rpc-session-spent rpc))
    ;; A deliberate respawn is not a death worth announcing.
    (let ((old (genie-rpc-session-proc rpc)))
      (set-process-sentinel old #'ignore)
      (delete-process old)))
  (unless (genie-rpc-live-p rpc)
    (let ((default-directory (genie-rpc-session-directory rpc))
          (errbuf (or (and (buffer-live-p (genie-rpc-session-stderr rpc))
                           (genie-rpc-session-stderr rpc))
                      (setf (genie-rpc-session-stderr rpc)
                            (generate-new-buffer " *genie-rpc stderr*")))))
      (with-current-buffer errbuf (erase-buffer))
      (setf (genie-rpc-session-acc rpc) ""
            (genie-rpc-session-spent rpc) nil
            (genie-rpc-session-next-id rpc) 0
            (genie-rpc-session-pending rpc) nil
            (genie-rpc-session-session-id rpc) nil
            (genie-rpc-session-queue rpc) nil
            (genie-rpc-session-proc rpc)
            (make-process
             :name "genie-rpc" :buffer nil :noquery t :connection-type 'pipe
             :command (genie-rpc-session-command rpc)
             :stderr (make-pipe-process :name "genie-rpc-stderr"
                                        :buffer errbuf :noquery t
                                        :sentinel #'ignore)
             :filter (lambda (_proc string) (genie-rpc--filter rpc string))
             :sentinel (lambda (proc _event) (genie-rpc--sentinel rpc proc))))
      (when-let* ((hello (genie-rpc--spec rpc :hello)))
        (funcall hello rpc)))))

(defun genie-rpc--send (rpc msg)
  "Send plist MSG to session RPC as one JSON line."
  (process-send-string (genie-rpc-session-proc rpc)
                       (concat (json-serialize msg) "\n")))

(defun genie-rpc--filter (rpc string)
  "Accumulate STRING for session RPC; dispatch complete JSON lines."
  (setf (genie-rpc-session-acc rpc)
        (concat (genie-rpc-session-acc rpc) string))
  (let ((lines (split-string (genie-rpc-session-acc rpc) "\n")))
    (setf (genie-rpc-session-acc rpc) (car (last lines)))
    (dolist (line (butlast lines))
      (unless (string-empty-p (string-trim line))
        (when-let* ((message (ignore-errors
                               (json-parse-string line :object-type 'plist
                                                  :null-object nil
                                                  :false-object nil))))
          (funcall (genie-rpc--spec rpc :dispatch) rpc message))))))

(defun genie-rpc--sentinel (rpc proc)
  "Fire the `:on-exit' handler of session RPC when PROC has died."
  (when (and (not (process-live-p proc))
             (eq proc (genie-rpc-session-proc rpc)))
    (genie-rpc--fire rpc :on-exit)))

;;;; Backend: elmee over the Agent Client Protocol (JSON-RPC 2.0, ndjson)

(defun genie-rpc--request (rpc method params handler)
  "Send JSON-RPC METHOD with PARAMS on session RPC.
HANDLER is called with (RESULT ERROR) when the agent answers."
  (let ((id (cl-incf (genie-rpc-session-next-id rpc))))
    (push (cons id handler) (genie-rpc-session-pending rpc))
    (genie-rpc--send rpc (append (list :jsonrpc "2.0" :id id :method method)
                                 (and params (list :params params))))))

(defun genie-rpc--acp-hello (rpc)
  "ACP handshake on session RPC: initialize, then open a session.
Prompts sent before the session is ready wait in the queue."
  (genie-rpc--request
   rpc "initialize" '(:protocolVersion 1)
   (lambda (_result err)
     (if err
         (genie-rpc--fire rpc :on-fail
                          (or (plist-get err :message) "initialize refused"))
       (genie-rpc--request
        rpc "session/new"
        (list :cwd (directory-file-name
                    (expand-file-name (genie-rpc-session-directory rpc))))
        (lambda (result err)
          (if err
              (genie-rpc--fire rpc :on-fail
                               (or (plist-get err :message)
                                   "session/new refused"))
            (setf (genie-rpc-session-session-id rpc)
                  (plist-get result :sessionId))
            (let ((queued (genie-rpc-session-queue rpc)))
              (setf (genie-rpc-session-queue rpc) nil)
              (dolist (text queued)
                (genie-rpc--acp-send-prompt rpc text))))))))))

(defun genie-rpc--acp-prompt (rpc text)
  "Send TEXT on session RPC, queueing it until the ACP session is open."
  (if (genie-rpc-session-session-id rpc)
      (genie-rpc--acp-send-prompt rpc text)
    (setf (genie-rpc-session-queue rpc)
          (append (genie-rpc-session-queue rpc) (list text)))))

(defun genie-rpc--acp-send-prompt (rpc text)
  "Send the `session/prompt' request carrying TEXT on session RPC.
The response ends the turn: any stop reason fires `:on-done' (streamed
text already arrived as updates), a refusal fires `:on-fail'."
  (genie-rpc--request
   rpc "session/prompt"
   (list :sessionId (genie-rpc-session-session-id rpc)
         :prompt (vector (list :type "text" :text text)))
   (lambda (_result err)
     (if err
         (genie-rpc--fire rpc :on-fail
                          (or (plist-get err :message) "prompt refused"))
       (genie-rpc--fire rpc :on-done nil)))))

(defun genie-rpc--acp-abort (rpc)
  "Cancel the ACP turn in flight on session RPC.
The pending `session/prompt' then answers with a cancelled stop reason."
  (when-let* ((session (genie-rpc-session-session-id rpc)))
    (genie-rpc--send rpc (list :jsonrpc "2.0" :method "session/cancel"
                               :params (list :sessionId session)))))

(defun genie-rpc--acp-update (rpc update)
  "Translate one `session/update' UPDATE plist into handler callbacks on RPC."
  (pcase (plist-get update :sessionUpdate)
    ("agent_message_chunk"
     (genie-rpc--fire rpc :on-text
                      (or (plist-get (plist-get update :content) :text) "")))
    ("tool_call"
     (genie-rpc--fire rpc :on-tool
                      (or (plist-get update :title)
                          (plist-get update :kind) "tool")))))

(defun genie-rpc--acp-dispatch (rpc message)
  "Dispatch one JSON-RPC MESSAGE from the ACP agent on session RPC.
Responses settle our pending requests; `session/update' notifications
stream the turn; requests from the agent are declined minimally, since
this client advertises no capabilities they could rely on."
  (let ((id (plist-get message :id))
        (method (plist-get message :method)))
    (cond
     ((and id (not method))             ; an answer to something we asked
      (when-let* ((cell (assq id (genie-rpc-session-pending rpc))))
        (setf (genie-rpc-session-pending rpc)
              (delq cell (genie-rpc-session-pending rpc)))
        (funcall (cdr cell)
                 (plist-get message :result) (plist-get message :error))))
     ((equal method "session/update")
      (genie-rpc--acp-update
       rpc (plist-get (plist-get message :params) :update)))
     ((and id method)                   ; a request from the agent
      (genie-rpc--send
       rpc (if (equal method "elicitation/create")
               (list :jsonrpc "2.0" :id id :result '(:action "cancel"))
             (list :jsonrpc "2.0" :id id
                   :error '(:code -32601 :message "not supported"))))))))

;;;; Backend: Pi (line-delimited JSON of Pi's own)

(defun genie-rpc--pi-prompt (rpc text)
  "Send TEXT as Pi's prompt message on session RPC."
  (genie-rpc--send rpc (list :type "prompt" :message text)))

(defun genie-rpc--pi-abort (rpc)
  "Send Pi's abort message on session RPC."
  (genie-rpc--send rpc '(:type "abort")))

(defun genie-rpc--pi-dispatch (rpc event)
  "Translate one Pi EVENT plist into handler callbacks on session RPC."
  (pcase (plist-get event :type)
    ("message_update"
     (let ((ev (plist-get event :assistantMessageEvent)))
       (when (and ev (equal (plist-get ev :type) "text_delta"))
         (genie-rpc--fire rpc :on-text (or (plist-get ev :delta) "")))))
    ("tool_execution_start"
     (genie-rpc--fire rpc :on-tool (or (plist-get event :toolName) "tool")))
    ("agent_end"
     (genie-rpc--fire rpc :on-done nil))))

(provide 'genie-rpc)
;;; genie-rpc.el ends here
