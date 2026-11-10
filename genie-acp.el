;;; genie-acp.el --- Agent Client Protocol client for elmee -*- lexical-binding: t; -*-

;; Copyright 2026 Sergei Belousov

;; Author: Sergei Belousov <sergei.o.belousov@gmail.com>
;; Maintainer: Sergei Belousov <sergei.o.belousov@gmail.com>
;; Version: 0.13.0
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

;; A client for the Agent Client Protocol (https://agentclientprotocol.com)
;; as the elmee agent serves it with `elmee --acp': JSON-RPC 2.0, one
;; message per line, over the stdio of one warm process.
;;
;; Two objects.  An *agent* is that process: started lazily, greeted
;; once, and able to hold any number of conversations.  A *session* is
;; one conversation in one directory, with the callbacks that receive
;; what the agent says in it.  Nothing here blocks: every answer arrives
;; through a callback, on Emacs's own event loop.
;;
;;   (setq agent (genie-acp-agent '("elmee" "--acp")))
;;   (setq session (genie-acp-open agent "~/project/"
;;                                 :on-text (lambda (delta) ...)
;;                                 :on-done (lambda (stop-reason) ...)))
;;   (genie-acp-prompt session "Refactor foo.el")
;;
;; The handlers a session may attach, all optional:
;;
;;   :on-text TEXT          a piece of the answer
;;   :on-thought TEXT       a piece of the model's reasoning
;;   :on-user TEXT          a past prompt, while a resumed session replays
;;   :on-tool CALL          a tool call starting (the update, as a plist)
;;   :on-tool-update CALL   that call ending
;;   :on-plan ENTRIES       the agent's plan, whenever it changes
;;   :on-usage USED SIZE    tokens in the context, and the window's size
;;   :on-commands LIST      what `/name' may be typed: (NAME . DESCRIPTION)
;;   :on-options OPTIONS    what can be chosen for the session (the model)
;;   :on-title TITLE        what the conversation is about
;;   :on-ask PARAMS REPLY   the agent asks a question; call REPLY with a
;;                          plist of answers, or nil to decline
;;   :on-done STOP-REASON   the turn ended ("end_turn", "cancelled", ...)
;;   :on-fail MESSAGE CODE  a request was refused
;;   :on-exit               the agent process died

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(cl-defstruct (genie-acp-agent (:constructor genie-acp--make-agent) (:copier nil))
  "One agent process, and what is known about it."
  command proc (acc "") stderr (next-id 0) pending
  ;; nil before the handshake, `greeting' during it, t after.
  ready
  ;; Thunks waiting for the handshake.
  waiting
  ;; Open sessions, as (ID . SESSION).
  sessions
  ;; The ways to sign in this agent offered, as the handshake listed them.
  auth-methods)

(cl-defstruct (genie-acp-session (:constructor genie-acp--make-session) (:copier nil))
  "One conversation with an agent, in one directory."
  agent directory id handlers
  ;; nil before it is opened, `opening' meanwhile, t after.
  state
  ;; Thunks waiting for it to open.
  waiting
  ;; A conversation to reopen instead of starting one, and whether what was
  ;; said in it should be played back through the handlers.
  resume replay)

(defconst genie-acp-auth-required -32000
  "The protocol's error code for \"sign in first\".")

;;;; The agent process

(defun genie-acp-agent (command)
  "Return an agent that will run COMMAND, an argv list, when first needed."
  (genie-acp--make-agent :command command))

(defun genie-acp-live-p (agent)
  "Return non-nil when AGENT has a live process."
  (and agent
       (genie-acp-agent-proc agent)
       (process-live-p (genie-acp-agent-proc agent))))

(defun genie-acp-shutdown (agent)
  "End the process of AGENT.  Its sessions reopen when next used."
  (when (genie-acp-live-p agent)
    (delete-process (genie-acp-agent-proc agent))))

(defun genie-acp-stderr (agent &optional lines)
  "Return the last LINES (default 10) AGENT wrote to stderr, or nil.
Stderr is kept apart from the protocol stream, so a process that dies
at startup has a readable reason."
  (when-let* ((buf (and agent (genie-acp-agent-stderr agent))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (save-excursion
          (goto-char (point-max))
          (forward-line (- (or lines 10)))
          (let ((tail (string-trim
                       (buffer-substring-no-properties (point) (point-max)))))
            (unless (string-empty-p tail) tail)))))))

(defun genie-acp--start (agent)
  "Start the process of AGENT and greet it."
  (let ((errbuf (or (and (buffer-live-p (genie-acp-agent-stderr agent))
                         (genie-acp-agent-stderr agent))
                    (setf (genie-acp-agent-stderr agent)
                          (generate-new-buffer " *genie-acp stderr*")))))
    (with-current-buffer errbuf (erase-buffer))
    (setf (genie-acp-agent-acc agent) ""
          (genie-acp-agent-next-id agent) 0
          (genie-acp-agent-pending agent) nil
          (genie-acp-agent-ready agent) 'greeting
          (genie-acp-agent-proc agent)
          (make-process
           :name "genie-acp" :buffer nil :noquery t :connection-type 'pipe
           :coding 'utf-8-unix
           :command (genie-acp-agent-command agent)
           :stderr (make-pipe-process :name "genie-acp-stderr"
                                      :buffer errbuf :noquery t
                                      :sentinel #'ignore)
           :filter (lambda (_proc string) (genie-acp--filter agent string))
           :sentinel (lambda (proc _event) (genie-acp--sentinel agent proc))))
    (genie-acp--request
     agent "initialize"
     ;; Saying a form can be shown is what lets the agent ask a question
     ;; instead of guessing: without it every question is cancelled unasked.
     '(:protocolVersion 1
       :clientCapabilities (:elicitation (:form nil))
       :clientInfo (:name "genie.el" :version "0.13.0"))
     (lambda (result err)
       (if err
           (genie-acp--fail-all agent (genie-acp--reason err "initialize refused"))
         (setf (genie-acp-agent-auth-methods agent)
               (append (plist-get result :authMethods) nil)
               (genie-acp-agent-ready agent) t)
         (let ((waiting (nreverse (genie-acp-agent-waiting agent))))
           (setf (genie-acp-agent-waiting agent) nil)
           (mapc #'funcall waiting)))))))

(defun genie-acp--when-ready (agent thunk)
  "Call THUNK once AGENT is running and greeted, starting it if need be."
  (if (and (genie-acp-live-p agent) (eq (genie-acp-agent-ready agent) t))
      (funcall thunk)
    (push thunk (genie-acp-agent-waiting agent))
    (unless (genie-acp-live-p agent)
      (genie-acp--start agent))))

(defun genie-acp--sentinel (agent proc)
  "Tell every session of AGENT that PROC, its process, has died.
The sessions are kept: each remembers the conversation it held and
reopens it — without replaying it — the next time it is used."
  (when (and (not (process-live-p proc))
             (eq proc (genie-acp-agent-proc agent)))
    (let ((sessions (mapcar #'cdr (genie-acp-agent-sessions agent))))
      (setf (genie-acp-agent-ready agent) nil
            (genie-acp-agent-waiting agent) nil
            (genie-acp-agent-sessions agent) nil)
      (dolist (session sessions)
        (setf (genie-acp-session-resume session) (genie-acp-session-id session)
              (genie-acp-session-replay session) nil
              (genie-acp-session-state session) nil
              (genie-acp-session-waiting session) nil)
        (genie-acp--fire session :on-exit)))))

(defun genie-acp--fail-all (agent message)
  "Report MESSAGE to every session waiting on AGENT."
  (setf (genie-acp-agent-waiting agent) nil)
  (dolist (cell (genie-acp-agent-sessions agent))
    (genie-acp--fire (cdr cell) :on-fail message nil)))

;;;; The wire

(defun genie-acp--send (agent message)
  "Send plist MESSAGE to AGENT as one JSON line."
  (process-send-string (genie-acp-agent-proc agent)
                       (concat (json-serialize message) "\n")))

(defun genie-acp--request (agent method params handler)
  "Send METHOD with PARAMS to AGENT; HANDLER gets (RESULT ERROR)."
  (let ((id (cl-incf (genie-acp-agent-next-id agent))))
    (push (cons id handler) (genie-acp-agent-pending agent))
    (genie-acp--send agent (list :jsonrpc "2.0" :id id
                                 :method method :params params))))

(defun genie-acp--reason (err fallback)
  "Return the message of ERR, a JSON-RPC error plist, or FALLBACK."
  (or (plist-get err :message) fallback))

(defun genie-acp--filter (agent string)
  "Accumulate STRING from AGENT; dispatch each complete JSON line."
  (setf (genie-acp-agent-acc agent)
        (concat (genie-acp-agent-acc agent) string))
  (let ((lines (split-string (genie-acp-agent-acc agent) "\n")))
    (setf (genie-acp-agent-acc agent) (car (last lines)))
    (dolist (line (butlast lines))
      (unless (string-empty-p (string-trim line))
        (when-let* ((message (ignore-errors
                               (json-parse-string line :object-type 'plist
                                                  :null-object nil
                                                  :false-object nil))))
          (genie-acp--dispatch agent message))))))

(defun genie-acp--dispatch (agent message)
  "Act on one MESSAGE from AGENT.
An answer settles the request it answers; a `session/update' goes to
the session it names; a question is put to that session; anything else
the agent asks for is declined, since nothing else was offered."
  (let ((id (plist-get message :id))
        (method (plist-get message :method))
        (params (plist-get message :params)))
    (cond
     ((and id (not method))
      (when-let* ((cell (assq id (genie-acp-agent-pending agent))))
        (setf (genie-acp-agent-pending agent)
              (delq cell (genie-acp-agent-pending agent)))
        (funcall (cdr cell)
                 (plist-get message :result) (plist-get message :error))))
     ((equal method "session/update")
      (when-let* ((session (genie-acp--session agent (plist-get params :sessionId))))
        (genie-acp--update session (plist-get params :update))))
     ((and id (equal method "elicitation/create"))
      (genie-acp--ask agent id params))
     (id
      (genie-acp--send agent (list :jsonrpc "2.0" :id id
                                   :error '(:code -32601
                                            :message "not supported")))))))

(defun genie-acp--session (agent id)
  "Return the session of AGENT known by ID, or nil."
  (cdr (assoc id (genie-acp-agent-sessions agent))))

(defun genie-acp--ask (agent id params)
  "Put the question in PARAMS to its session; answer request ID of AGENT.
A session with nobody to ask, or one that declines, cancels it — which
the agent takes as \"decide for yourself\", not as a failure."
  (let* ((form (plist-get (plist-get params :mode) :form))
         (session (genie-acp--session
                   agent (plist-get (plist-get form :scope) :sessionId)))
         (reply (lambda (answers)
                  (genie-acp--send
                   agent
                   (list :jsonrpc "2.0" :id id
                         :result (if answers
                                     (list :action "accept" :content answers)
                                   '(:action "cancel")))))))
    (if (and session (plist-get (genie-acp-session-handlers session) :on-ask))
        (genie-acp--fire session :on-ask params reply)
      (funcall reply nil))))

(defun genie-acp--update (session update)
  "Translate one `session/update' UPDATE into the handlers of SESSION."
  (let ((text (lambda () (or (plist-get (plist-get update :content) :text) ""))))
    (pcase (plist-get update :sessionUpdate)
      ("agent_message_chunk" (genie-acp--fire session :on-text (funcall text)))
      ("agent_thought_chunk" (genie-acp--fire session :on-thought (funcall text)))
      ("user_message_chunk" (genie-acp--fire session :on-user (funcall text)))
      ("tool_call" (genie-acp--fire session :on-tool update))
      ("tool_call_update" (genie-acp--fire session :on-tool-update update))
      ("plan" (genie-acp--fire session :on-plan
                               (append (plist-get update :entries) nil)))
      ("usage_update"
       (genie-acp--fire session :on-usage
                        (plist-get update :used) (plist-get update :size)))
      ("available_commands_update"
       (genie-acp--fire
        session :on-commands
        (mapcar (lambda (command)
                  (cons (plist-get command :name)
                        (or (plist-get command :description) "")))
                (plist-get update :availableCommands))))
      ("config_option_update"
       (genie-acp--fire session :on-options
                        (append (plist-get update :configOptions) nil)))
      ("session_info_update"
       (genie-acp--fire session :on-title (plist-get update :title))))))

(defun genie-acp--fire (session key &rest args)
  "Call the KEY handler of SESSION with ARGS, when one is attached."
  (when-let* ((fn (plist-get (genie-acp-session-handlers session) key)))
    (apply fn args)))

;;;; Sessions

(defun genie-acp-open (agent directory &rest handlers)
  "Return a conversation with AGENT in DIRECTORY, with HANDLERS attached.
Nothing is started until it is first used.  Among HANDLERS (see the
commentary of this file), `:resume ID' reopens the conversation ID
names instead of starting one, playing back what was said in it."
  (genie-acp--make-session
   :agent agent
   :directory (directory-file-name (expand-file-name directory))
   :handlers handlers
   :resume (plist-get handlers :resume)
   :replay (and (plist-get handlers :resume) t)))

(defun genie-acp-ensure (session thunk)
  "Call THUNK once SESSION is open, opening it if need be."
  (if (eq (genie-acp-session-state session) t)
      (funcall thunk)
    (push thunk (genie-acp-session-waiting session))
    (unless (genie-acp-session-state session)
      (setf (genie-acp-session-state session) 'opening)
      (genie-acp--when-ready
       (genie-acp-session-agent session)
       (lambda () (genie-acp--open session))))))

(defun genie-acp--open (session)
  "Ask the agent for SESSION: a new conversation, or the one it resumes."
  (let* ((agent (genie-acp-session-agent session))
         (resume (genie-acp-session-resume session))
         (params (list :cwd (genie-acp-session-directory session)
                       :mcpServers [])))
    (when resume
      ;; What was said is played back before the request is answered, so
      ;; the session has to be findable by its id already.
      (setf (genie-acp-session-id session) resume)
      (push (cons resume session) (genie-acp-agent-sessions agent)))
    (genie-acp--request
     agent
     (cond ((not resume) "session/new")
           ((genie-acp-session-replay session) "session/load")
           (t "session/resume"))
     (if resume (append (list :sessionId resume) params) params)
     (lambda (result err)
       (if err
           (progn
             (setf (genie-acp-session-state session) nil
                   (genie-acp-session-waiting session) nil
                   (genie-acp-agent-sessions agent)
                   (rassq-delete-all session (genie-acp-agent-sessions agent)))
             (genie-acp--fire session :on-fail
                              (genie-acp--reason err "the session did not open")
                              (plist-get err :code)))
         (unless resume
           (setf (genie-acp-session-id session) (plist-get result :sessionId))
           (push (cons (genie-acp-session-id session) session)
                 (genie-acp-agent-sessions agent)))
         (setf (genie-acp-session-state session) t)
         (when-let* ((options (plist-get result :configOptions)))
           (genie-acp--fire session :on-options (append options nil)))
         (let ((waiting (nreverse (genie-acp-session-waiting session))))
           (setf (genie-acp-session-waiting session) nil)
           (mapc #'funcall waiting)))))))

(defun genie-acp-prompt (session content)
  "Send CONTENT as the next turn of SESSION.
CONTENT is a string, or a list of content blocks: plists such as
\(:type \"text\" :text ...) and (:type \"resource\" :resource ...).
The turn's end arrives at `:on-done' with why it stopped; a refusal at
`:on-fail' with the message and its code."
  (let ((blocks (if (stringp content)
                    (list (list :type "text" :text content))
                  content)))
    (genie-acp-ensure
     session
     (lambda ()
       (genie-acp--request
        (genie-acp-session-agent session) "session/prompt"
        (list :sessionId (genie-acp-session-id session)
              :prompt (vconcat blocks))
        (lambda (result err)
          (if err
              (genie-acp--fire session :on-fail
                               (genie-acp--reason err "the prompt was refused")
                               (plist-get err :code))
            (genie-acp--fire session :on-done
                             (or (plist-get result :stopReason) "end_turn")))))))))

(defun genie-acp-cancel (session)
  "Stop the turn in flight on SESSION; it then ends as \"cancelled\"."
  (when (and (eq (genie-acp-session-state session) t)
             (genie-acp-live-p (genie-acp-session-agent session)))
    (genie-acp--send (genie-acp-session-agent session)
                     (list :jsonrpc "2.0" :method "session/cancel"
                           :params (list :sessionId
                                         (genie-acp-session-id session))))))

(defun genie-acp-close (session)
  "End SESSION.  The agent forgets it; what was said stays on disk."
  (let ((agent (genie-acp-session-agent session)))
    (when (and (eq (genie-acp-session-state session) t)
               (genie-acp-live-p agent))
      (genie-acp--request agent "session/close"
                          (list :sessionId (genie-acp-session-id session))
                          #'ignore))
    (setf (genie-acp-session-state session) nil
          (genie-acp-session-waiting session) nil
          (genie-acp-agent-sessions agent)
          (rassq-delete-all session (genie-acp-agent-sessions agent)))))

(defun genie-acp-set (session option value callback)
  "Choose VALUE for OPTION (such as \"model\") on SESSION.
CALLBACK gets nil on success, or the reason it was refused."
  (genie-acp-ensure
   session
   (lambda ()
     (genie-acp--request
      (genie-acp-session-agent session) "session/set_config_option"
      (list :sessionId (genie-acp-session-id session)
            :configId option :value value)
      (lambda (_result err)
        (funcall callback (and err (genie-acp--reason err "refused"))))))))

;;;; What an agent can be asked apart from any session

(defun genie-acp-list (agent directory callback)
  "Ask AGENT for the conversations kept for DIRECTORY, newest first.
CALLBACK gets a list of plists with `:sessionId', `:title', `:updatedAt'
and `:prompts', or nil and a reason."
  (genie-acp--when-ready
   agent
   (lambda ()
     (genie-acp--request
      agent "session/list"
      (list :cwd (directory-file-name (expand-file-name directory)))
      (lambda (result err)
        (if err
            (funcall callback nil (genie-acp--reason err "could not list"))
          (funcall
           callback
           (mapcar (lambda (session)
                     (append session
                             (list :prompts
                                   (plist-get (plist-get (plist-get session :_meta)
                                                         :elmee)
                                              :prompts))))
                   (plist-get result :sessions))
           nil)))))))

(defun genie-acp-delete (agent id callback)
  "Ask AGENT to delete the conversation ID; CALLBACK gets nil or a reason."
  (genie-acp--when-ready
   agent
   (lambda ()
     (genie-acp--request
      agent "session/delete" (list :sessionId id)
      (lambda (_result err)
        (funcall callback (and err (genie-acp--reason err "refused"))))))))

(defun genie-acp-sign-in (agent callback)
  "Sign AGENT in by the first way it offered; CALLBACK gets nil or a reason.
The agent does the signing in itself — for elmee, a browser — and
answers when it is over."
  (genie-acp--when-ready
   agent
   (lambda ()
     (if-let* ((method (car (genie-acp-agent-auth-methods agent))))
         (genie-acp--request
          agent "authenticate" (list :methodId (plist-get method :id))
          (lambda (_result err)
            (funcall callback (and err (genie-acp--reason err "refused")))))
       (funcall callback "this agent offers no way to sign in")))))

(provide 'genie-acp)
;;; genie-acp.el ends here
