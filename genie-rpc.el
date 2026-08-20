;;; genie-rpc.el --- Async duplex JSONL RPC to AI coding-agent CLIs -*- lexical-binding: t; -*-

;; Copyright 2026 Sergei Belousov

;; Author: Sergei Belousov <sergei.o.belousov@gmail.com>
;; Maintainer: Sergei Belousov <sergei.o.belousov@gmail.com>
;; Version: 0.1.0
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

;; Application-agnostic plumbing for driving AI coding agents that speak
;; JSON lines over stdio.  A session normalizes each backend's event
;; stream into a small set of handler callbacks and hides lifecycle
;; differences, so an application never blocks the single-threaded UI
;; and never parses agent-specific JSON itself.
;;
;; Two backends ship with the library, registered in `genie-rpc-backends':
;;
;; - `pi'    — the Pi coding agent (`pi --mode rpc'): one persistent
;;             process holds the whole conversation.
;; - `elmee' — the elmee agent microkernel (`elmee --rpc'): one process
;;             per task; callers keep context across tasks by passing an
;;             `--session FILE' argument in the command.
;;
;; Adding a backend is adding an entry to `genie-rpc-backends': a prompt
;; encoder, an event dispatcher, and lifecycle keywords.  No other code
;; in this file is backend-specific.
;;
;; Typical use:
;;
;;   (setq rpc (genie-rpc-open 'pi (list "pi" "--mode" "rpc")
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
  backend command directory proc (acc "") spent handlers)

(defvar genie-rpc-backends
  '((pi :persistent t
        :prompt genie-rpc--pi-prompt
        :abort (:type "abort")
        :dispatch genie-rpc--pi-dispatch)
    (elmee :persistent nil
           :prompt genie-rpc--elmee-prompt
           :abort nil
           :stop (:type "stop")
           :dispatch genie-rpc--elmee-dispatch))
  "Registry of agent backends, keyed by symbol.
Each entry is (NAME . PLIST) with:
  :persistent  non-nil when one process serves many prompts; nil when
               the agent runs one task per process and must be respawned
  :prompt      function TEXT -> plist, the JSON line carrying a prompt
  :abort       plist sent to interrupt a turn, or nil when the backend
               has none (the process is then ended instead)
  :stop        optional plist asking the process to exit gracefully
  :dispatch    function (SESSION EVENT) translating one parsed event
               plist into `genie-rpc--fire' handler calls.")

;;;; Session lifecycle

(defun genie-rpc-open (backend command &rest opts)
  "Create a session for BACKEND, running COMMAND (an argv list).
The process starts lazily on the first `genie-rpc-prompt'.  OPTS is a
plist: `:directory' sets the working directory, and the handler keys
`:on-text' (answer text delta), `:on-tool' (name of a starting tool),
`:on-done' (final answer string or nil), `:on-fail' (error message),
`:on-request' (interaction request plist, answer via `genie-rpc-respond';
auto-cancelled when no handler is given) and `:on-exit' (no arguments,
the process died) attach callbacks."
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
Starts the agent process when needed; a spent one-task-per-process
agent is replaced by a fresh one running the same command."
  (genie-rpc--ensure rpc)
  (genie-rpc--send rpc (funcall (genie-rpc--spec rpc :prompt) text))
  (unless (genie-rpc--spec rpc :persistent)
    (setf (genie-rpc-session-spent rpc) t)))

(defun genie-rpc-abort (rpc)
  "Interrupt the turn in flight on session RPC.
When the backend has no abort input, ending the process is the abort."
  (when (genie-rpc-live-p rpc)
    (if-let* ((msg (genie-rpc--spec rpc :abort)))
        (genie-rpc--send rpc msg)
      (genie-rpc-close rpc))))

(defun genie-rpc-close (rpc)
  "End the agent process of session RPC.
Backends with a `:stop' message get a graceful exit first, with a kill
fallback shortly after — an idle agent does not always honor stop, and
a lingering process may hold locks (for example on a session file)."
  (when (genie-rpc-live-p rpc)
    (let ((proc (genie-rpc-session-proc rpc)))
      (if-let* ((msg (genie-rpc--spec rpc :stop)))
          (progn
            (ignore-errors (genie-rpc--send rpc msg))
            (run-at-time 3 nil (lambda ()
                                 (when (process-live-p proc)
                                   (delete-process proc)))))
        (delete-process proc)))))

(defun genie-rpc-respond (rpc id response)
  "Answer the interaction request ID on session RPC with RESPONSE.
RESPONSE is a backend-specific plist; for elmee, for example,
\(:outcome \"deny\" :value \"reason\") or (:outcome \"cancel\")."
  (genie-rpc--send rpc (list :type "interaction_response"
                             :id id :response response)))

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
    (delete-process (genie-rpc-session-proc rpc)))
  (unless (genie-rpc-live-p rpc)
    (let ((default-directory (genie-rpc-session-directory rpc)))
      (setf (genie-rpc-session-acc rpc) ""
            (genie-rpc-session-spent rpc) nil
            (genie-rpc-session-proc rpc)
            (make-process
             :name "genie-rpc" :buffer nil :noquery t :connection-type 'pipe
             :command (genie-rpc-session-command rpc)
             :filter (lambda (_proc string) (genie-rpc--filter rpc string))
             :sentinel (lambda (proc _event) (genie-rpc--sentinel rpc proc)))))))

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
        (when-let* ((event (ignore-errors
                             (json-parse-string line :object-type 'plist
                                                :null-object nil
                                                :false-object nil))))
          (funcall (genie-rpc--spec rpc :dispatch) rpc event))))))

(defun genie-rpc--sentinel (rpc proc)
  "Fire the `:on-exit' handler of session RPC when PROC has died."
  (when (and (not (process-live-p proc))
             (eq proc (genie-rpc-session-proc rpc)))
    (genie-rpc--fire rpc :on-exit)))

;;;; Backend: Pi

(defun genie-rpc--pi-prompt (text)
  "Pi's prompt message carrying TEXT."
  (list :type "prompt" :message text))

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

;;;; Backend: elmee

(defun genie-rpc--elmee-prompt (text)
  "Elmee's prompt message carrying TEXT."
  (list :type "prompt" :text text))

(defun genie-rpc--elmee-dispatch (rpc event)
  "Translate one elmee EVENT plist into handler callbacks on session RPC."
  (pcase (plist-get event :type)
    ("text"
     (genie-rpc--fire rpc :on-text (or (plist-get event :text) "")))
    ("tool_start"
     (genie-rpc--fire rpc :on-tool (or (plist-get event :name) "tool")))
    ("result"
     (genie-rpc-close rpc)              ; one task per process
     (genie-rpc--fire rpc :on-done (plist-get event :answer)))
    ((or "error" "paused")
     (genie-rpc--fire rpc :on-fail
                      (or (plist-get event :message) "agent error")))
    ("interaction_request"
     (let ((request (plist-get event :request)))
       (if (plist-get (genie-rpc-session-handlers rpc) :on-request)
           (genie-rpc--fire rpc :on-request request)
         (genie-rpc-respond rpc (plist-get request :id)
                            '(:outcome "cancel")))))))

(provide 'genie-rpc)
;;; genie-rpc.el ends here
