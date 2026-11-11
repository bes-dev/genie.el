;;; genie-tests.el --- Tests for genie, genie-chat and genie-acp -*- lexical-binding: t; -*-

;; Copyright 2026 Sergei Belousov
;; SPDX-License-Identifier: Apache-2.0

;;; Commentary:

;; ERT suite: the ACP client (framing, handshake, sessions, questions,
;; tools), the chat buffer (transcript, skills, the list of
;; conversations), wishes that can be taken back, Emacs as the agent's
;; tools, genie's git pipeline (snapshot / detect / reject / commit /
;; undo), validation, the turn state machine, the lamp, and the
;; spell/cantrip pipeline with the unified undo journal.  No network and
;; no real agent needed.

;;; Code:

(require 'ert)
(require 'warnings)
(require 'genie)

;;;; Helpers

(defmacro genie-tests--with-repo (&rest body)
  "Run BODY with `genie-config-root' bound to a fresh throwaway git repo."
  (declare (indent 0))
  `(let* ((genie-config-root (make-temp-file "genie-tests-repo" t))
          (genie-wish-directory (expand-file-name "wishes" genie-config-root))
          (genie-wish--all nil) (genie--cautions nil)
          (warning-suppress-log-types '((genie)))
          (genie--changed nil) (genie--created nil) (genie--verdict nil)
          (genie--pre nil) (genie--pre-untracked nil) (genie--repairs 0)
          (genie--wish nil) (genie--journal nil) (genie--state 'idle))
     (unwind-protect
         (progn
           (genie--git "init" "-q")
           (genie--git "config" "user.email" "test@test")
           (genie--git "config" "user.name" "test")
           (make-directory genie-wish-directory t)
           ,@body)
       (dolist (wish (genie-wish-list))
         (genie-wish-off (plist-get wish :name)))
       (delete-directory genie-config-root t))))

(defun genie-tests--write (name content)
  "Write CONTENT to file NAME under the test repo."
  (let ((file (expand-file-name name (genie--root))))
    (make-directory (file-name-directory file) t)
    (with-temp-file file (insert content))))

(defun genie-tests--read (name)
  "Return the content of file NAME under the test repo."
  (with-temp-buffer
    (insert-file-contents (expand-file-name name (genie--root)))
    (buffer-string)))

(defmacro genie-tests--with-agent (agent sent &rest body)
  "Run BODY with AGENT bound to an agent whose wire is captured in SENT.
No process is started: what would be written to it is pushed onto SENT,
newest first, and `genie-tests--say' plays the agent's side."
  (declare (indent 2))
  `(let ((,agent (genie-acp-agent '("true"))) (,sent nil))
     (cl-letf (((symbol-function 'genie-acp--start)
                (lambda (agent)
                  (setf (genie-acp-agent-ready agent) 'greeting
                        (genie-acp-agent-next-id agent) 0)
                  (genie-acp--request
                   agent "initialize" nil
                   (lambda (result _err)
                     (setf (genie-acp-agent-auth-methods agent)
                           (append (plist-get result :authMethods) nil)
                           (genie-acp-agent-ready agent) t)
                     (mapc #'funcall
                           (prog1 (nreverse (genie-acp-agent-waiting agent))
                             (setf (genie-acp-agent-waiting agent) nil)))))))
               ((symbol-function 'genie-acp-live-p)
                (lambda (agent) (genie-acp-agent-ready agent)))
               ((symbol-function 'genie-acp--send)
                (lambda (_agent message) (push message ,sent))))
       ,@body)))

(defun genie-tests--say (agent &rest messages)
  "Feed MESSAGES, plists, to AGENT as lines the agent process wrote."
  (dolist (message messages)
    (genie-acp--filter agent (concat (json-serialize message) "\n"))))

(defun genie-tests--answer (agent id result)
  "Answer request ID of AGENT with RESULT."
  (genie-tests--say agent (list :jsonrpc "2.0" :id id :result result)))

(defun genie-tests--update (agent session &rest update)
  "Send AGENT a `session/update' for SESSION carrying UPDATE."
  (genie-tests--say agent (list :jsonrpc "2.0" :method "session/update"
                                :params (list :sessionId session
                                              :update update))))

;;;; genie-acp: the protocol

(ert-deftest genie-acp-line-framing ()
  "JSON lines split across arbitrary chunks are reassembled, UTF-8 and all."
  (genie-tests--with-agent agent _sent
    (let* ((texts nil)
           (session (genie-acp-open agent "/tmp"
                                    :on-text (lambda (s) (push s texts))))
           (line (concat (json-serialize
                          '(:jsonrpc "2.0" :method "session/update"
                            :params (:sessionId "s"
                                     :update (:sessionUpdate "agent_message_chunk"
                                              :content (:type "text"
                                                        :text "привет")))))
                         "\n")))
      (push (cons "s" session) (genie-acp-agent-sessions agent))
      (genie-acp--filter agent (substring line 0 40))
      (genie-acp--filter agent (substring line 40 55))
      (genie-acp--filter agent (substring line 55))
      (genie-acp--filter agent line)
      (should (equal texts '("привет" "привет"))))))

(ert-deftest genie-acp-handshake-and-turn ()
  "The whole cycle: greeting, a session, a queued prompt, a streamed turn."
  (genie-tests--with-agent agent sent
    (let* ((log nil)
           (session
            (genie-acp-open
             agent "/tmp/project/"
             :on-text (lambda (s) (push (cons 'text s) log))
             :on-tool (lambda (call) (push (cons 'tool (plist-get call :title)) log))
             :on-tool-update (lambda (call)
                               (push (cons 'ended (plist-get call :status)) log))
             :on-plan (lambda (entries) (push (cons 'plan (length entries)) log))
             :on-usage (lambda (used size) (push (list 'usage used size) log))
             :on-commands (lambda (commands) (push (cons 'commands commands) log))
             :on-options (lambda (options)
                           (push (cons 'options (length options)) log))
             :on-done (lambda (stop) (push (cons 'done stop) log)))))
      ;; nothing is started until the first prompt, which then waits
      (should-not sent)
      (genie-acp-prompt session "make it so")
      (should (equal (plist-get (car sent) :method) "initialize"))
      (genie-tests--answer agent 1 '(:protocolVersion 1))
      (should (equal (plist-get (car sent) :method) "session/new"))
      (should (equal (plist-get (plist-get (car sent) :params) :cwd)
                     "/tmp/project"))
      (genie-tests--answer
       agent 2 '(:sessionId "/s.jsonl"
                 :configOptions [(:id "model" :currentValue "m1")]))
      ;; the session is open: the queued prompt goes out under its id
      (let ((params (plist-get (car sent) :params)))
        (should (equal (plist-get (car sent) :method) "session/prompt"))
        (should (equal (plist-get params :sessionId) "/s.jsonl"))
        (should (equal (plist-get (aref (plist-get params :prompt) 0) :text)
                       "make it so")))
      (genie-tests--update agent "/s.jsonl" :sessionUpdate "available_commands_update"
                           :availableCommands [(:name "pdf" :description "read PDFs")])
      (genie-tests--update agent "/s.jsonl" :sessionUpdate "plan"
                           :entries [(:content "a" :status "pending")])
      (genie-tests--update agent "/s.jsonl" :sessionUpdate "tool_call"
                           :toolCallId "1" :title "apply_patch init.el")
      (genie-tests--update agent "/s.jsonl" :sessionUpdate "tool_call_update"
                           :toolCallId "1" :status "completed")
      (genie-tests--update agent "/s.jsonl" :sessionUpdate "agent_message_chunk"
                           :content '(:type "text" :text "done"))
      (genie-tests--update agent "/s.jsonl" :sessionUpdate "usage_update"
                           :used 100 :size 1000)
      ;; an update for a session nobody here holds is dropped, not an error
      (genie-tests--update agent "/other.jsonl" :sessionUpdate "agent_message_chunk"
                           :content '(:type "text" :text "not ours"))
      (genie-tests--answer agent 3 '(:stopReason "end_turn"))
      (should (equal (nreverse log)
                     '((options . 1) (commands ("pdf" . "read PDFs")) (plan . 1)
                       (tool . "apply_patch init.el") (ended . "completed")
                       (text . "done") (usage 100 1000) (done . "end_turn")))))))

(ert-deftest genie-acp-refusals-carry-their-code ()
  "A refused prompt reaches `:on-fail' with its code — which is how
\"sign in first\" is told from any other failure."
  (genie-tests--with-agent agent _sent
    (let* ((failed nil)
           (session (genie-acp-open agent "/tmp"
                                    :on-fail (lambda (message code)
                                               (setq failed (cons message code))))))
      (genie-acp-prompt session "hi")
      (genie-tests--answer agent 1 nil)
      (genie-tests--answer agent 2 '(:sessionId "s"))
      (genie-tests--say agent '(:jsonrpc "2.0" :id 3
                                :error (:code -32000 :message "sign-in required")))
      (should (equal failed (cons "sign-in required" genie-acp-auth-required))))))

(ert-deftest genie-acp-resume-is-findable-before-it-answers ()
  "A resumed conversation is played back before `session/load' is answered."
  (genie-tests--with-agent agent sent
    (let* ((said nil)
           (session (genie-acp-open agent "/tmp" :resume "/old.jsonl"
                                    :on-user (lambda (text) (push text said)))))
      (genie-acp-ensure session #'ignore)
      (genie-tests--answer agent 1 nil)
      (should (equal (plist-get (car sent) :method) "session/load"))
      (should (equal (plist-get (plist-get (car sent) :params) :sessionId)
                     "/old.jsonl"))
      (genie-tests--update agent "/old.jsonl" :sessionUpdate "user_message_chunk"
                           :content '(:type "text" :text "earlier"))
      (should (equal said '("earlier")))
      (genie-tests--answer agent 2 nil)
      (should (eq (genie-acp-session-state session) t)))))

(ert-deftest genie-acp-a-dead-agent-is-reopened-where-it-left-off ()
  "After the process dies a session reopens its conversation, unreplayed."
  (genie-tests--with-agent agent sent
    (let* ((exited nil)
           (session (genie-acp-open agent "/tmp"
                                    :on-exit (lambda () (setq exited t)))))
      (genie-acp-ensure session #'ignore)
      (genie-tests--answer agent 1 nil)
      (genie-tests--answer agent 2 '(:sessionId "/s.jsonl"))
      (let ((proc (start-process "genie-tests-true" nil "true")))
        (setf (genie-acp-agent-proc agent) proc)
        (while (process-live-p proc) (accept-process-output proc 0.1))
        (genie-acp--sentinel agent proc))
      (should exited)
      (should-not (genie-acp-session-state session))
      (genie-acp-prompt session "still there?")
      (genie-tests--answer agent 1 nil)
      (should (equal (plist-get (car sent) :method) "session/resume"))
      (should (equal (plist-get (plist-get (car sent) :params) :sessionId)
                     "/s.jsonl")))))

(ert-deftest genie-acp-questions-are-answered-or-declined ()
  "A question goes to the session it names; with nobody to ask it is cancelled."
  (genie-tests--with-agent agent sent
    (let* ((session (genie-acp-open
                     agent "/tmp"
                     :on-ask (lambda (_params reply)
                               (funcall reply '(:q0 "This file")))))
           (ask (lambda (id scope)
                  (genie-tests--say
                   agent
                   (list :jsonrpc "2.0" :id id :method "elicitation/create"
                         :params (list :mode (list :form (list :scope scope))))))))
      (push (cons "s" session) (genie-acp-agent-sessions agent))
      (funcall ask "q-1" '(:sessionId "s"))
      (should (equal (plist-get (car sent) :id) "q-1"))
      (should (equal (plist-get (car sent) :result)
                     '(:action "accept" :content (:q0 "This file"))))
      (funcall ask "q-2" '(:sessionId "nobody"))
      (should (equal (plist-get (plist-get (car sent) :result) :action) "cancel"))
      ;; anything else the agent asks for was never offered
      (genie-tests--say agent '(:jsonrpc "2.0" :id "f-1" :method "fs/read_text_file"))
      (should (= (plist-get (plist-get (car sent) :error) :code) -32601)))))

;;;; genie-chat: the buffer

(defmacro genie-tests--with-chat (&rest body)
  "Run BODY in a fresh chat buffer about a throwaway directory."
  (declare (indent 0))
  `(let* ((directory (make-temp-file "genie-tests-chat" t))
          (chat (genie-chat-open directory :name " *genie-tests-chat*")))
     (unwind-protect
         (with-current-buffer chat ,@body)
       (kill-buffer chat)
       (delete-directory directory t))))

(ert-deftest genie-chat-transcript-grows-above-what-is-being-typed ()
  "Output lands above the prompt, so a half-typed message is left alone."
  (genie-tests--with-chat
    (goto-char (point-max))
    (insert "half a thought")
    (genie-chat--on-user "first")
    (setq genie-chat--busy t)
    (genie-chat--on-text "an ")
    (genie-chat--on-text "answer")
    (should (equal (buffer-substring-no-properties genie-chat--input (point-max))
                   "half a thought"))
    (should (string-match-p "\nfirst\n\nan answer\n❯ half a thought\\'"
                            (buffer-string)))
    ;; the transcript cannot be typed into; the message can
    (should-error (progn (goto-char (point-min)) (insert "x")))
    (goto-char (point-max))
    (insert "!")))

(ert-deftest genie-chat-tool-lines-say-how-they-ended ()
  "A tool call is one line, marked when it ends, with the reason if it failed."
  (genie-tests--with-chat
    (genie-chat--on-tool '(:toolCallId "1" :title "read init.el"))
    (genie-chat--on-tool '(:toolCallId "2" :title "exec make"))
    (genie-chat--on-tool-update '(:toolCallId "1" :status "completed"))
    (genie-chat--on-tool-update
     '(:toolCallId "2" :status "failed"
       :content [(:type "content"
                  :content (:type "text" :text "make: *** no rule\n[exit status: 2]"))]))
    (should (string-match-p "✓ read init.el\n✗ exec make\n  make: \\*\\*\\* no rule\n"
                            (buffer-string)))))

(ert-deftest genie-chat-dresses-an-answer-as-it-arrives ()
  "Each finished line is dressed where it stands; the words are left alone."
  (genie-tests--with-chat
    (let* ((file (expand-file-name "notes.md" directory))
           (said (format "See %s:3 and [[notes]], not /no/such/file; \
docs at https://example.com/docs." file))
           (answer (concat "# Result\n" said "\n- **done** with `make`\n"
                           "```elisp\n(+ 1 2)\n```\nlast")))
      (with-temp-file file (insert "a\nb\nc\n"))
      (setq genie-chat--busy (current-time))
      ;; in pieces that respect no line, as a model sends them
      (dolist (piece (seq-partition answer 7))
        (genie-chat--on-text piece))
      (cl-flet ((at (text) (goto-char (point-min)) (search-forward text)
                    (match-beginning 0)))
        ;; what was written is all still there
        (should (string-search answer (buffer-string)))
        ;; and it reads as what it means
        (should (get-text-property (at "# ") 'invisible))
        (should (eq (get-text-property (at "Result") 'face)
                    'genie-markdown-heading))
        (should (get-text-property (at "**done") 'invisible))
        (should (memq 'bold (ensure-list (get-text-property (at "done") 'face))))
        (should (get-text-property (at "- **") 'display))
        (should (memq 'genie-markdown-code
                      (ensure-list (get-text-property (at "make") 'face))))
        (should (equal (get-text-property (at "```elisp") 'display) "elisp"))
        (should (string-match-p "│" (get-text-property (at "(+ 1 2)") 'line-prefix)))
        (should (equal (button-get (button-at (at "notes.md")) 'file) file))
        (should (= (button-get (button-at (at "notes.md")) 'line) 3))
        (should (equal (button-get (button-at (at "[[notes")) 'page) "notes"))
        (should-not (button-at (at "/no/such")))
        (should (equal (button-get (button-at (at "example.com")) 'url)
                       "https://example.com/docs")))
      (let ((genie-chat-wiki-roots (list directory)))
        (cl-letf (((symbol-function 'find-file-other-window)
                   (lambda (found) (should (equal found file)))))
          (genie-chat--open-page "notes"))))))

(ert-deftest genie-chat-a-tool-call-reads-as-what-is-done ()
  "A command as typed, a file by its name here, a question to Emacs as one."
  (genie-tests--with-chat
    (let ((there (expand-file-name "src/a.el" directory)))
      (should (equal (genie-chat--call-title
                      '(:title "exec make test" :kind "execute"
                        :rawInput (:command "make test\necho done")))
                     "$ make test"))
      (should (equal (genie-chat--call-title
                      `(:title "apply_patch" :kind "edit"
                        :locations [(:path ,there)]))
                     "edit src/a.el"))
      (should (equal (genie-chat--call-title
                      '(:title "mcp__emacs__describe" :kind "other"
                        :rawInput (:key "C-c d")))
                     "λ describe C-c d"))
      (should (equal (genie-chat--call-title '(:title "web_search emacs"))
                     "web_search emacs")))))

(ert-deftest genie-chat-a-turn-carries-what-was-attached ()
  "What `genie-ask' attached goes with the next message, once."
  (genie-tests--with-chat
    (let (sent)
      (cl-letf (((symbol-function 'genie-acp-prompt)
                 (lambda (_session blocks) (setq sent blocks))))
        (push (cons "init.el:1-2" '(:type "resource" :resource (:text "x")))
              genie-chat--attached)
        (genie-chat-submit (current-buffer) "explain this")
        (should (equal (mapcar (lambda (block) (plist-get block :type)) sent)
                       '("resource" "text")))
        (should-not genie-chat--attached)
        (should (string-match-p "\nexplain this\n\n📎 init.el:1-2" (buffer-string)))
        ;; a second message while that one runs is refused, not queued
        (should-error (genie-chat-submit (current-buffer) "and this")
                      :type 'user-error)))))

(ert-deftest genie-chat-earlier-messages-come-back-to-be-sent-again ()
  "M-p walks back through what was said here; M-n returns to the blank."
  (genie-tests--with-chat
    (genie-chat--on-user "first")
    (genie-chat--on-user "second")
    (cl-flet ((typed () (buffer-substring-no-properties genie-chat--input
                                                        (point-max))))
      (genie-chat-earlier)
      (should (equal (typed) "second"))
      (genie-chat-earlier)
      (should (equal (typed) "first"))
      (should-error (genie-chat-earlier) :type 'user-error)
      (genie-chat-later)
      (should (equal (typed) "second"))
      (genie-chat-later)
      (should (equal (typed) "")))))

(ert-deftest genie-chat-a-skill-name-completes-at-the-start-of-a-message ()
  "`/name' is completed from what the agent offers, and only up front."
  (genie-tests--with-chat
    (setq genie-chat--commands '(("pdf" . "read PDFs") ("goal" . "set a goal")))
    (goto-char (point-max))
    (insert "/pd")
    (pcase-let ((`(,beg ,end ,table . ,_) (genie-chat--complete-skill)))
      (should (equal (buffer-substring beg end) "pd"))
      (should (equal (all-completions "pd" table) '("pdf"))))
    (insert "f some.pdf")
    (should-not (genie-chat--complete-skill))))

(ert-deftest genie-chat-questions-go-to-the-minibuffer ()
  "Each field of the agent's question is asked; quitting declines them all."
  (genie-tests--with-chat
    (let* ((answers 'unanswered)
           (params '(:mode (:form (:requestedSchema
                                   (:properties
                                    (:q0 (:title "Scope" :description "How far?"
                                          :enum ["This file" "Whole crate"])
                                     :q1 (:title "Tests" :enum ["yes" "no"])))))))
           (reply (lambda (given) (setq answers given))))
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (_time _repeat function) (funcall function)))
                ((symbol-function 'completing-read)
                 (lambda (_prompt choices &rest _) (cadr choices))))
        (genie-chat--on-ask params reply))
      (should (equal answers '(:q0 "Whole crate" :q1 "no")))
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (_time _repeat function) (funcall function)))
                ((symbol-function 'completing-read)
                 (lambda (&rest _) (signal 'quit nil))))
        (genie-chat--on-ask params reply))
      (should-not answers))))

(ert-deftest genie-acp-what-is-not-the-conversation-has-handlers-too ()
  "Notices, compactions and the agents a session started reach its handlers."
  (genie-tests--with-agent agent sent
    (let* ((log nil)
           (session
            (genie-acp-open
             agent "/tmp/project/"
             :on-notice (lambda (severity title) (push (list severity title) log))
             :on-compaction (lambda (status) (push status log))
             :on-child (lambda (id title state) (push (list id title state) log))
             :on-child-tool (lambda (title call)
                              (push (list title (plist-get call :title)) log)))))
      (genie-acp-ensure session #'ignore)
      (genie-tests--answer agent 1 '(:protocolVersion 1))
      (genie-tests--answer agent 2 '(:sessionId "/s.jsonl"))
      (genie-tests--update agent "/s.jsonl" :sessionUpdate "notice"
                           :severity "warning" :title "skipping MCP server x")
      (genie-tests--update agent "/s.jsonl" :sessionUpdate "compaction_summary_chunk"
                           :compactionId "c" :content '(:type "text" :text "so far"))
      (genie-tests--update agent "/s.jsonl" :sessionUpdate "compaction_update"
                           :compactionId "c" :status "completed")
      ;; a child speaks under its own id, and is heard only once announced
      (genie-tests--update agent "/child.jsonl" :sessionUpdate "tool_call"
                           :toolCallId "0" :title "too early")
      (genie-tests--update agent "/s.jsonl" :sessionUpdate "subagent_update"
                           :sessionId "/child.jsonl" :title "helper"
                           :state '(:state "running"))
      (genie-tests--update agent "/child.jsonl" :sessionUpdate "tool_call"
                           :toolCallId "1" :title "exec make")
      (genie-tests--update agent "/child.jsonl" :sessionUpdate "agent_message_chunk"
                           :content '(:type "text" :text "its own words"))
      (genie-tests--update agent "/s.jsonl" :sessionUpdate "subagent_update"
                           :sessionId "/child.jsonl" :state '(:state "idle"))
      (should (equal (nreverse log)
                     '(("warning" "skipping MCP server x")
                       "in_progress" "completed"
                       ("/child.jsonl" "helper" "running")
                       ("helper" "exec make")
                       ("/child.jsonl" "helper" "idle"))))
      (should-not (genie-acp-agent-children agent)))))

(ert-deftest genie-acp-call-names-its-session-and-says-why-not ()
  "Anything else asked of a session carries its id; a refusal is a reason."
  (genie-tests--with-agent agent sent
    (let ((session (genie-acp-open agent "/tmp/project/")) got)
      (genie-acp-call session "_session/rewind" '(:promptId 3)
                      (lambda (result reason) (push (list result reason) got)))
      (genie-tests--answer agent 1 '(:protocolVersion 1))
      (genie-tests--answer agent 2 '(:sessionId "/s.jsonl"))
      (should (equal (plist-get (car sent) :params)
                     '(:sessionId "/s.jsonl" :promptId 3)))
      (genie-tests--answer agent 3 '(:prompt "again"))
      (genie-acp-rename agent "/old.jsonl" "notes" (lambda (reason) (push reason got)))
      (should (equal (plist-get (car sent) :method) "session/set_title"))
      (genie-tests--say agent '(:jsonrpc "2.0" :id 4 :error (:code -32602 :message "no session")))
      (should (equal got '("no session" ((:prompt "again") nil)))))))

(ert-deftest genie-chat-what-is-typed-during-a-turn-steers-it ()
  "RET while the agent works corrects the turn in flight instead of waiting."
  (genie-tests--with-chat
    (let (called submitted)
      (cl-letf (((symbol-function 'genie-acp-call)
                 (lambda (_session method params callback)
                   (push (list method params) called)
                   (funcall callback '(:outcome "injected") nil)))
                ((symbol-function 'genie-acp-prompt)
                 (lambda (_session blocks) (setq submitted blocks))))
        (setq genie-chat--busy (current-time))
        (goto-char (point-max))
        (insert "not that file")
        (genie-chat-send)
        (should (equal (caar called) "_session/steering"))
        (should (equal (plist-get (aref (plist-get (cadar called) :prompt) 0) :text)
                       "not that file"))
        (should (string-match-p "\nnot that file\n" (buffer-string)))
        (should (= genie-chat--input (point-max)))
        (should-not submitted)
        ;; a turn that ended in the meantime gets it as its next prompt
        (cl-letf (((symbol-function 'genie-acp-call)
                   (lambda (_session _method _params callback)
                     (setq genie-chat--busy nil)
                     (funcall callback '(:outcome "promptRequired") nil))))
          (insert "and then this")
          (genie-chat-send)
          (should (equal (plist-get (car submitted) :text) "and then this")))))))

(ert-deftest genie-chat-going-back-returns-the-message-to-be-edited ()
  "A rewind says the conversation again and puts the message after the prompt."
  (genie-tests--with-chat
    (let (called)
      (cl-letf (((symbol-function 'genie-acp-call)
                 (lambda (_session method params callback)
                   (push (list method params) called)
                   (pcase method
                     ("_session/history"
                      (funcall callback
                               '(:prompts [(:id 1 :text "first" :checkpoint t)
                                           (:id 4 :text "second" :checkpoint t)])
                               nil))
                     ("_session/rewind" (funcall callback '(:prompt "second") nil))
                     ("session/load"
                      (genie-chat--on-user "first")
                      (funcall callback nil nil)))))
                ((symbol-function 'run-at-time)
                 (lambda (_time _repeat function &rest args) (apply function args)))
                ((symbol-function 'completing-read)
                 (lambda (_prompt choices &rest _) (caar choices)))
                ((symbol-function 'read-multiple-choice)
                 (lambda (&rest _) '(?c "conversation"))))
        (genie-chat--on-user "first")
        (genie-chat--on-user "second")
        (genie-chat-rewind)
        ;; the newest message is offered first, and is the one gone back to
        (should (equal (cadr (assoc "_session/rewind" called))
                       '(:promptId 4 :restore "conversation")))
        (should (equal (buffer-substring-no-properties genie-chat--input (point-max))
                       "second"))
        (should (string-match-p "\\`first\n" (buffer-string)))
        (should-not (string-match-p "\nsecond\n" (buffer-string)))
        (should (string-match-p "back to before this message" (buffer-string)))))))

(ert-deftest genie-chat-says-what-happens-beside-the-conversation ()
  "A helper's work, a compaction and a notice are asides in the transcript."
  (genie-tests--with-chat
    (genie-chat--on-child "/c.jsonl" "helper" "running")
    (genie-chat--on-child "/c.jsonl" "helper" "running")
    (genie-chat--on-child-tool "helper" '(:title "exec make"))
    (should (string-match-p "1 helping" (genie-chat--header)))
    (genie-chat--on-child "/c.jsonl" "helper" "idle")
    (setq genie-chat--busy (current-time))
    (genie-chat--on-compaction "in_progress")
    (should (string-match-p "making room" (genie-chat--header)))
    (genie-chat--on-compaction "completed")
    (genie-chat--on-notice "warning" "skipping MCP server x")
    (should-not (string-match-p "helping\\|making room" (genie-chat--header)))
    (should (string-match-p
             "⤷ helper started\n  ⤷ helper · exec make\n⤷ helper finished\n— earlier conversation summarized to make room —\n⚠ skipping MCP server x\n"
             (buffer-string)))))

(ert-deftest genie-sessions-say-how-long-ago ()
  "The list tells age the way a person would, and survives a missing date."
  (let ((ago (lambda (seconds)
               (genie-sessions--ago
                (format-time-string "%FT%TZ" (time-subtract nil seconds) t)))))
    (should (equal (funcall ago 5) "just now"))
    (should (equal (funcall ago 600) "10 min ago"))
    (should (equal (funcall ago 7200) "2 h ago"))
    (should (equal (funcall ago 259200) "3 d ago"))
    (should (equal (genie-sessions--ago nil) ""))))

;;;; genie: git pipeline

;;;; genie: git pipeline

(ert-deftest genie-git-snapshot-and-detect ()
  "Snapshot baselines and change detection, including created files."
  (genie-tests--with-repo
    (genie-tests--write "a.el" "(setq a 1)\n")
    (genie-tests--write "b.el" "(setq b 1)\n")
    (genie--git "add" "-A")
    (genie--git "commit" "-qm" "base")
    (genie-tests--write "b.el" "(setq b 2)\n") ; user WIP before the wish
    (genie--snapshot)
    (should (equal (genie--pre-dirty) '("b.el")))
    (genie-tests--write "a.el" "(setq a 2)\n")
    (genie-tests--write "b.el" "(setq b 3)\n")
    (genie-tests--write "c.el" "(setq c 1)\n")
    (genie--detect-changes)
    (should (equal (sort (copy-sequence genie--changed) #'string<)
                   '("a.el" "b.el" "c.el")))
    (should (equal genie--created '("c.el")))))

(ert-deftest genie-snapshot-survives-a-staged-leftover ()
  "A file left staged by an interrupted review must not break the snapshot.
Created files are staged outright — the intent-to-add entries of older
genies were what `git stash create' refused to merge."
  (genie-tests--with-repo
    (genie-tests--write "a.el" "(setq a 1)\n")
    (genie--git "add" "-A")
    (genie--git "commit" "-qm" "base")
    (genie-tests--write "GENIE.md" "# leftover manual\n")
    (genie--git "add" "--" "GENIE.md")         ; what a lost review leaves
    (genie--snapshot)                          ; must not signal
    (genie-tests--write "b.el" "(setq b 1)\n")
    (genie--detect-changes)
    (should (member "b.el" genie--changed))
    (should (equal (genie-tests--read "GENIE.md") "# leftover manual\n"))))

(ert-deftest genie-git-reject-restores ()
  "Reject restores the pre-wish worktree but keeps the user's own WIP."
  (genie-tests--with-repo
    (genie-tests--write "a.el" "(setq a 1)\n")
    (genie-tests--write "b.el" "(setq b 1)\n")
    (genie--git "add" "-A")
    (genie--git "commit" "-qm" "base")
    (genie-tests--write "b.el" "(setq b 2)\n") ; user WIP
    (genie--snapshot)
    (genie-tests--write "a.el" "(setq a 2)\n")
    (genie-tests--write "b.el" "(setq b 3)\n")
    (genie-tests--write "c.el" "(setq c 1)\n")
    (genie--detect-changes)
    (setq genie--state 'reviewing)
    (genie-reject)
    (should (equal (genie-tests--read "a.el") "(setq a 1)\n"))
    (should (equal (genie-tests--read "b.el") "(setq b 2)\n"))
    (should-not (file-exists-p (expand-file-name "c.el" (genie--root))))
    (should-not genie--changed)
    (should (eq genie--state 'idle))))

(ert-deftest genie-git-commit-and-undo ()
  "Apply commits only touched files; undo confirms, then drops the commit.
The commit leaves history entirely, its created files leave the
worktree, and unrelated uncommitted work survives untouched."
  (genie-tests--with-repo
    (genie-tests--write "a.el" "(setq a 1)\n")
    (genie-tests--write "b.el" "(setq b 1)\n")
    (genie--git "add" "-A")
    (genie--git "commit" "-qm" "base")
    (genie-tests--write "b.el" "(setq b 2)\n") ; user WIP, must survive
    (genie--snapshot)
    (genie-tests--write "a.el" "(setq a 5)\n")
    (genie-tests--write "d.el" "(setq d 1)\n")
    (genie--detect-changes)
    (setq genie--wish "make a five")
    (apply #'genie--git "commit" "-m" (format "genie: %s" genie--wish)
           "--" genie--changed)
    (genie--reset)
    (should (string-prefix-p "genie: make a five"
                             (genie--git "log" "-1" "--format=%s")))
    (should (member "b.el" (split-string
                            (genie--git "diff" "--name-only" "HEAD") "\n" t)))
    ;; undo asks first; declining leaves the commit alone
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) nil)))
      (should-error (genie-undo) :type 'user-error))
    (should (string-prefix-p "genie: " (genie--git "log" "-1" "--format=%s")))
    (cl-letf (((symbol-function 'genie--refresh) #'ignore)
              ((symbol-function 'y-or-n-p) (lambda (_) t)))
      (genie-undo))
    (should (equal (genie-tests--read "a.el") "(setq a 1)\n"))
    (should-not (file-exists-p (expand-file-name "d.el" (genie--root))))
    (should (equal (genie-tests--read "b.el") "(setq b 2)\n"))
    ;; the commit is gone from history, not reverted on top of it
    (should (equal (genie--git "log" "--format=%s") "base"))))

(ert-deftest genie-reload-covers-init-el ()
  "Reload evaluates changed modules first, then init.el itself."
  (genie-tests--with-repo
    (genie-tests--write "mod.el" "(setq genie-tests--mod-loaded t)\n")
    (genie-tests--write
     "init.el"
     "(setq genie-tests--init-saw-mod (bound-and-true-p genie-tests--mod-loaded))\n")
    (setq genie-tests--mod-loaded nil genie-tests--init-saw-mod nil)
    (genie--refresh '("mod.el" "init.el" "GENIE.md"))
    (should (bound-and-true-p genie-tests--mod-loaded))
    (should (bound-and-true-p genie-tests--init-saw-mod)))) ; init ran last

(ert-deftest genie-reload-failure-offers-restart ()
  "A file that fails to load falls back to the restart offer, not a crash."
  (genie-tests--with-repo
    (genie-tests--write "boom.el" "(error \"broken module\")\n")
    (let (asked)
      (cl-letf (((symbol-function 'y-or-n-p)
                 (lambda (prompt) (setq asked prompt) nil)))
        (genie--refresh '("boom.el")))
      (should (string-match-p "boom\\.el" asked)))))

(ert-deftest genie-undo-warns-only-about-overlapping-edits ()
  "The drop prompt names later edits to the wish's files, and only those."
  (genie-tests--with-repo
    (genie-tests--write "a.el" "(setq a 1)\n")
    (genie-tests--write "b.el" "(setq b 1)\n")
    (genie--git "add" "-A")
    (genie--git "commit" "-qm" "base")
    (genie-tests--write "a.el" "(setq a 5)\n")
    (genie--git "commit" "-qm" "genie: five" "--" "a.el")
    ;; unrelated WIP must not be mentioned…
    (genie-tests--write "b.el" "(setq b 99)\n")
    (let (prompt)
      (cl-letf (((symbol-function 'y-or-n-p)
                 (lambda (p) (setq prompt p) nil)))
        (should-error (genie--undo-wish nil) :type 'user-error))
      (should-not (string-match-p "b\\.el" prompt))
      ;; …but a later edit to the wish's own file must be
      (genie-tests--write "a.el" "(setq a 7)\n")
      (cl-letf (((symbol-function 'y-or-n-p)
                 (lambda (p) (setq prompt p) nil)))
        (should-error (genie--undo-wish nil) :type 'user-error))
      (should (string-match-p "a\\.el" prompt)))
    ;; declining changed nothing
    (should (equal (genie-tests--read "b.el") "(setq b 99)\n"))
    (should (string-prefix-p "genie: " (genie--git "log" "-1" "--format=%s")))))

(ert-deftest genie-undo-refuses-foreign-head ()
  "Undo refuses when HEAD is not a genie commit."
  (genie-tests--with-repo
    (genie-tests--write "a.el" "(setq a 1)\n")
    (genie--git "add" "-A")
    (genie--git "commit" "-qm" "base")
    (should-error (genie-undo) :type 'user-error)))

;;;; genie: validation and state machine

(ert-deftest genie-parens-check ()
  "The parens validator accepts balanced files and pinpoints broken ones."
  (genie-tests--with-repo
    (genie-tests--write "ok.el" "(defun f () 1)\n")
    (genie-tests--write "bad.el" "(defun f ( () 1)\n")
    (let ((genie--changed '("ok.el")))
      (should (car (genie--parens-check))))
    (let ((genie--changed '("ok.el" "bad.el")))
      (let ((verdict (genie--parens-check)))
        (should-not (car verdict))
        (should (string-match-p "bad\\.el" (cdr verdict)))))))

(ert-deftest genie-state-blocks-new-turns ()
  "Turns cannot start while one is thinking or validating."
  (dolist (state '(thinking validating))
    (let ((genie--state state))
      (should-error (genie--submit "x") :type 'user-error)))
  (let ((genie--state 'thinking))
    (should-error (genie--require-ready) :type 'user-error)))

(ert-deftest genie-state-guards-review-commands ()
  "Apply and reject demand the reviewing state; undo demands idle."
  (let ((genie--state 'thinking) (genie--changed '("a.el")))
    (should-error (genie-apply) :type 'user-error)
    (should-error (genie-reject) :type 'user-error)
    (should-error (genie-undo) :type 'user-error)))

(ert-deftest genie-indicator-installs-once ()
  "The activity element goes into `global-mode-string' exactly once.
It is a literal form rather than a variable, so a reloaded genie needs
no healing: the form calls whatever `genie--activity' is current."
  (let ((global-mode-string nil))
    (genie--install-indicator)
    (genie--install-indicator)
    (should (= 1 (cl-count genie--indicator global-mode-string :test #'equal)))
    (should (equal genie--indicator '(:eval (genie--activity))))))

(ert-deftest genie-spinner-follows-state ()
  "The spinner timer runs while genie works and stops when it is quiet."
  (let ((genie--state 'idle) (genie--spinner-timer nil)
        (genie--spinner-index 0) (genie--tool nil))
    (unwind-protect
        (progn
          (genie--set-state 'thinking)
          (should (timerp genie--spinner-timer))
          (should (string-match-p "thinking\\." (genie--activity)))
          ;; the dots breathe: one, two, three, then one again
          (should (equal (mapcar (lambda (i)
                                   (let ((genie--spinner-index i))
                                     (genie--activity)))
                                 '(0 1 2 3))
                         '(" 🧞 thinking.  " " 🧞 thinking.. "
                           " 🧞 thinking..." " 🧞 thinking.  ")))
          (genie--set-state 'validating)
          (should (timerp genie--spinner-timer))
          (should (string-match-p "validating\\." (genie--activity)))
          (genie--set-state 'idle)
          (should-not genie--spinner-timer)
          (should (equal (genie--activity) "")))
      (when (timerp genie--spinner-timer)
        (cancel-timer genie--spinner-timer)))))

(ert-deftest genie-finish-turn-ignores-late-events ()
  "A finish outside the thinking state must not re-run the pipeline."
  (let ((genie--state 'idle))
    (cl-letf (((symbol-function 'genie--detect-changes)
               (lambda () (error "Pipeline ran twice"))))
      (genie--finish-turn))))                   ; no error means it was ignored

;;;; genie: the confirmation dial

(ert-deftest genie-confirm-dial ()
  "`genie--confirm-p' reads the dial."
  (let ((genie-confirm '(wish risky-code undo)))
    (should (genie--confirm-p 'wish))
    (should (genie--confirm-p 'undo)))
  (let ((genie-confirm '(risky-code)))
    (should-not (genie--confirm-p 'wish))
    (should (genie--confirm-p 'risky-code)))
  (let ((genie-confirm nil))
    (should-not (genie--confirm-p 'risky-code))))

(ert-deftest genie-instant-wish-skips-the-review ()
  "Without `wish' confirmation a validated change applies straight away."
  (let ((genie-confirm nil) (genie--state 'thinking)
        (genie--changed '("a.el")) applied shown)
    (cl-letf (((symbol-function 'genie--detect-changes) #'ignore)
              ((symbol-function 'genie--validate)
               (lambda (cb) (funcall cb '(t . "ok"))))
              ((symbol-function 'genie-apply) (lambda () (setq applied t)))
              ((symbol-function 'genie--show-diff) (lambda () (setq shown t))))
      (genie--finish-turn))
    (should applied)
    (should-not shown)))

(defmacro genie-tests--failing-turn (&rest body)
  "Run a wish turn whose validation fails, with the outcomes recorded.
BODY sees `applied', `shown', `repaired' and `gave-up'."
  (declare (indent 0))
  `(let ((genie--state 'thinking)
         (genie--changed '("a.el")) applied shown repaired gave-up)
     (cl-letf (((symbol-function 'genie--detect-changes) #'ignore)
               ((symbol-function 'genie--validate)
                (lambda (cb) (funcall cb '(nil . "void-function foo"))))
               ((symbol-function 'genie-apply) (lambda () (setq applied t)))
               ((symbol-function 'genie--show-diff) (lambda () (setq shown t)))
               ((symbol-function 'genie--repair)
                (lambda (_) (setq repaired t)))
               ((symbol-function 'genie--give-up)
                (lambda (_) (setq gave-up t))))
       (genie--finish-turn))
     ,@body))

(ert-deftest genie-failed-validation-goes-back-to-the-agent ()
  "A broken change is handed back for repair before anyone is bothered."
  (dolist (confirm '(nil (wish)))            ; in both flows
    (let ((genie-confirm confirm) (genie-repair-attempts 2) (genie--repairs 0))
      (genie-tests--failing-turn
        (should repaired)
        (should-not (or applied shown gave-up))
        (should (= genie--repairs 0))))))    ; the stub did not count a try

(ert-deftest genie-exhausted-repairs-undo-quietly-in-the-instant-flow ()
  "Out of attempts, a beginner gets the change undone — not a diff to judge."
  (let ((genie-confirm nil) (genie-repair-attempts 2) (genie--repairs 2))
    (genie-tests--failing-turn
      (should gave-up)
      (should-not (or applied shown repaired)))))

(ert-deftest genie-exhausted-repairs-review-when-asked ()
  "Out of attempts, someone who reviews diffs is shown one."
  (let ((genie-confirm '(wish)) (genie-repair-attempts 2) (genie--repairs 2))
    (genie-tests--failing-turn
      (should shown)
      (should-not (or applied gave-up repaired))
      (should (= genie--repairs 0)))))       ; the counter is cleared for next time

(ert-deftest genie-give-up-restores-the-worktree ()
  "Giving up undoes the change: files restored, created ones deleted."
  (genie-tests--with-repo
    (genie-tests--write "a.el" "(setq a 1)\n")
    (genie--git "add" "-A")
    (genie--git "commit" "-qm" "base")
    (genie--snapshot)
    (genie-tests--write "a.el" "(setq a (broken\n")
    (genie-tests--write "new.el" "(setq new 1)\n")
    (genie--detect-changes)
    (setq genie--wish "break everything" genie--repairs 2)
    (cl-letf (((symbol-function 'display-buffer) #'ignore))
      (genie--give-up '(nil . "end-of-file")))
    (should (equal (genie-tests--read "a.el") "(setq a 1)\n"))
    (should-not (file-exists-p (expand-file-name "new.el" (genie--root))))
    (should-not genie--changed)
    (should (eq genie--state 'idle))
    (should (= genie--repairs 0))
    ;; nothing was committed, and the index is clean for the next wish
    (should (equal (genie--git "log" "--format=%s") "base"))
    (should (equal (genie--git "status" "--porcelain") ""))))

(ert-deftest genie-repair-turn-stays-out-of-the-commit-message ()
  "A repair turn does not append itself to the wish used as commit message."
  (genie-tests--with-repo
    (genie-tests--write "a.el" "(setq a 1)\n")
    (genie--git "add" "-A")
    (genie--git "commit" "-qm" "base")
    (let ((genie--state 'idle) (genie--changed nil) (genie--wish nil)
          (genie--repairs 0) sent)
      (cl-letf (((symbol-function 'genie-acp-prompt)
                 (lambda (_session blocks)
                   (setq sent (plist-get (car (last blocks)) :text))))
                ((symbol-function 'genie--install-indicator) #'ignore))
        (unwind-protect
            (progn
              (genie--submit "add a keybinding")
              (should (equal genie--wish "add a keybinding"))
              (should (eq genie--state 'thinking))
              ;; the turn ends with a change pending, which fails to load
              (with-current-buffer (genie--buffer) (setq genie-chat--busy nil))
              (setq genie--changed '("a.el"))
              (genie--set-state 'reviewing)
              (genie--repair '(nil . "void-function foo"))
              (should (equal genie--wish "add a keybinding")) ; unchanged
              (should (string-match-p "void-function foo" sent))
              (should (= genie--repairs 1)))
          (kill-buffer (genie--buffer))
          (genie--set-state 'idle))))))

(ert-deftest genie-a-turn-typed-into-the-chat-is-a-wish-too ()
  "RET in the config chat opens the same pipeline `M-x genie' does."
  (genie-tests--with-repo
    (genie-tests--write "a.el" "(setq a 1)\n")
    (genie--git "add" "-A")
    (genie--git "commit" "-qm" "base")
    (cl-letf (((symbol-function 'genie-acp-prompt) #'ignore)
              ((symbol-function 'genie--install-indicator) #'ignore))
      (unwind-protect
          (with-current-buffer (genie--buffer)
            (goto-char (point-max))
            (insert "bind C-c f")
            (genie-chat-send)
            (should (equal genie--wish "bind C-c f"))
            (should (eq genie--state 'thinking))
            (should genie--pre))
        (kill-buffer (genie--buffer))
        (genie--set-state 'idle)))))

(ert-deftest genie-a-turn-that-did-not-finish-is-held-not-applied ()
  "Stopped mid-edit, what the agent left is neither committed nor discarded."
  (dolist (stop '("cancelled" "max_turn_requests" failed exited))
    (let ((genie-confirm nil) (genie--state 'thinking)
          (genie--changed '("a.el")) (genie--verdict '(t . "stale")) touched)
      (cl-letf (((symbol-function 'genie--detect-changes) #'ignore)
                ((symbol-function 'genie--validate)
                 (lambda (_) (setq touched 'validated)))
                ((symbol-function 'genie-apply) (lambda () (setq touched 'applied)))
                ((symbol-function 'genie--restore-worktree)
                 (lambda () (setq touched 'restored))))
        (genie--finish-turn stop))
      (should-not touched)
      (should (eq genie--state 'reviewing))
      (should-not genie--verdict))))

(ert-deftest genie-instant-undo-skips-the-prompt ()
  "Without `undo' confirmation the commit is dropped without asking…"
  (genie-tests--with-repo
    (let ((genie-confirm nil) asked)
      (genie-tests--write "a.el" "(setq a 1)\n")
      (genie--git "add" "-A")
      (genie--git "commit" "-qm" "base")
      (genie-tests--write "a.el" "(setq a 5)\n")
      (genie--git "commit" "-qm" "genie: five" "--" "a.el")
      (cl-letf (((symbol-function 'genie--refresh) #'ignore)
                ((symbol-function 'y-or-n-p) (lambda (_) (setq asked t) t)))
        (genie--undo-wish nil))
      (should-not asked)
      (should (equal (genie--git "log" "--format=%s") "base"))
      ;; …unless the user's own later edits would go with it
      (genie-tests--write "a.el" "(setq a 9)\n")
      (genie--git "commit" "-qm" "genie: nine" "--" "a.el")
      (genie-tests--write "a.el" "(setq a 10)\n")   ; later edit of your own
      (cl-letf (((symbol-function 'genie--refresh) #'ignore)
                ((symbol-function 'y-or-n-p) (lambda (_) (setq asked t) nil)))
        (should-error (genie--undo-wish nil) :type 'user-error))
      (should asked))))

(ert-deftest genie-instant-risky-code-reports-instead-of-asking ()
  "Without the gate risky code is evaluated, but the call is still named."
  (let ((genie-confirm nil) (genie--spell nil) (genie--spells nil)
        (genie--pending-register nil) (genie--cantrip-target nil)
        said)
    (cl-letf (((symbol-function 'yes-or-no-p)
               (lambda (_) (error "Must not ask")))
              ((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) said))))
      (genie--learn-spell
       "(defun genie-spell/risky () (interactive) (shell-command \"ls\"))"))
    (should (eq (genie--spell-name genie--spell) 'genie-spell/risky))
    (should (cl-some (lambda (s) (string-match-p "shell-command" s)) said))))

;;;; genie: maintainer charter

(ert-deftest genie-charter-covers-maintainer-duties ()
  "The system prompt carries the charter: the forms, the wish file, the rules."
  (genie-tests--with-repo
    (let ((prompt (genie--context-prompt)))
      (dolist (duty '("An answer" "An act" "A wish file" "genie-wish"
                      "cannot be taken back" "one thread" "thin bootstrap"
                      "docstring" "ask before granting"))
        (should (string-match-p duty prompt)))
      (should (string-match-p (regexp-quote genie-manual-file) prompt)))))

(ert-deftest genie-manual-requires-existing-file ()
  "`genie-manual' refuses politely when no manual has grown yet."
  (genie-tests--with-repo
    (should-error (genie-manual) :type 'user-error)))

;;;; genie: spells

(ert-deftest genie-extract-elisp ()
  "Code extraction handles fenced blocks and bare code."
  (should (equal (genie--extract-elisp "text\n```elisp\n(+ 1 2)\n```\ntail")
                 "(+ 1 2)\n"))
  (should (equal (genie--extract-elisp "(+ 1 2)") "(+ 1 2)")))

(ert-deftest genie-eval-spell ()
  "Spell evaluation returns the interactive command, or errors clearly."
  (should (eq (genie--eval-spell
               "(defun genie-spell/test-noop () (interactive) 42)")
              'genie-spell/test-noop))
  (should-error (genie--eval-spell "(setq genie-tests--nothing 1)")))

(ert-deftest genie-risky-code-gate ()
  "Conjured code calling risky functions is screened; declining discards it."
  (should (equal (genie--mentions
                  "(defun f () (interactive) (shell-command \"ls\"))"
                  genie-risky-functions)
                 '(shell-command)))
  (should-not (genie--mentions "(defun f () (interactive) (upcase 1))"
                               genie-risky-functions))
  (let ((genie--spell 'sentinel) (genie--spells nil)
        (genie--pending-register nil))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) nil))
              ((symbol-function 'display-buffer) #'ignore))
      (genie--learn-spell
       "(defun genie-spell/evil () (interactive) (delete-file \"x\"))"))
    (should (eq genie--spell 'sentinel))        ; nothing armed
    (should-not (fboundp 'genie-spell/evil))))  ; nothing evaluated

(defvar genie-tests--conjuring nil "Handlers of the conjuring under test.")

(defmacro genie-tests--conjuring (&rest body)
  "Run BODY with the spell agent replaced by a recording of what it is asked.
`genie-tests--conjured' then answers as the agent would."
  (declare (indent 0))
  `(let ((genie--spell-agent nil) (genie--spell-session nil)
         (genie-tests--conjuring nil))
     (cl-letf (((symbol-function 'genie-acp-open)
                (lambda (agent _directory &rest handlers)
                  (setq genie-tests--conjuring (cons agent handlers))
                  'session))
               ((symbol-function 'genie-acp-prompt) #'ignore)
               ((symbol-function 'genie-acp-close) #'ignore)
               ((symbol-function 'genie--install-indicator) #'ignore)
               ((symbol-function 'genie--emit) #'ignore))
       ,@body)))

(defun genie-tests--spell-argv ()
  "Return the part of the spell agent's argv that strips it of tools."
  (let ((argv (genie-acp-agent-command (car genie-tests--conjuring))))
    (cl-subseq (member "--tools" argv) 0 2)))

(defun genie-tests--conjured (answer)
  "Deliver ANSWER as the spell agent's whole reply, and end its turn."
  (funcall (plist-get (cdr genie-tests--conjuring) :on-text) answer)
  (funcall (plist-get (cdr genie-tests--conjuring) :on-done) "end_turn"))

(ert-deftest genie-spell-pipeline ()
  "A full spell turn arms a working region command; a bad reply keeps it."
  (let ((genie--spell nil) (genie--spells nil)
        (genie--state 'idle) (genie--changed nil)
        (genie--pending-register nil) (genie--journal nil))
    (genie-tests--conjuring
      (genie--conjure "number the lines" "spell: number the lines")
      (should (eq genie--state 'thinking))
      (should (equal (genie-tests--spell-argv) '("--tools" "")))
      (genie-tests--conjured
            (concat "```elisp\n"
                    "(defun genie-spell/number-lines (beg end)\n"
                    "  \"Number the lines of the region.\"\n"
                    "  (interactive \"r\")\n"
                    "  (save-excursion\n"
                    "    (goto-char beg)\n"
                    "    (let ((n 0) (endm (copy-marker end)))\n"
                    "      (while (< (point) endm)\n"
                    "        (insert (format \"%d. \" (setq n (1+ n))))\n"
                    "        (forward-line 1)))))\n"
                    "```")))
    (should (eq (genie--spell-name genie--spell) 'genie-spell/number-lines))
    (should (eq genie--state 'idle))
    (with-temp-buffer
      (insert "alpha\nbeta\ngamma\n")
      (funcall (genie--spell-fn genie--spell) (point-min) (point-max))
      (should (equal (buffer-string) "1. alpha\n2. beta\n3. gamma\n")))
    ;; a reply without an interactive defun keeps the previous spell armed
    (let ((previous genie--spell))
      (cl-letf (((symbol-function 'display-buffer) #'ignore))
        (genie--learn-spell "```elisp\n(setq genie-tests--var 1)\n```"))
      (should (eq genie--spell previous)))))

(ert-deftest genie-spell-registers ()
  "Registers store spell entries; casting an empty register errors clearly."
  (let ((genie--registers nil) (genie--spells nil) (genie--spell nil)
        (genie--journal nil) (genie--pending-register ?3)
        (genie--cantrip-target nil))
    (cl-letf (((symbol-function 'display-buffer) #'ignore))
      (genie--learn-spell
       "(defun genie-spell/test-reg () (interactive) 'cast)"))
    (let ((entry (alist-get ?3 genie--registers)))
      (should (eq (genie--spell-name entry) 'genie-spell/test-reg))
      (should-not genie--pending-register)
      (should (eq (genie-cast-register ?3) 'cast))
      (should-error (genie-cast-register ?7) :type 'user-error)
      ;; rebinding a register evicts the old entry in place
      (genie--bind-register ?3 (list 'other #'ignore ""))
      (should (eq (genie--spell-name (alist-get ?3 genie--registers))
                  'other)))))

(ert-deftest genie-spell-labels-uniquify ()
  "Reused spell names get distinct labels, and old entries keep old code."
  (let ((genie--spells nil) (genie--spell nil) (genie--registers nil)
        (genie--pending-register nil) (genie--cantrip-target nil))
    (cl-letf (((symbol-function 'display-buffer) #'ignore))
      (genie--learn-spell
       "(defun genie-spell/twice () (interactive) 'first)")
      (let ((old (genie--spell-fn genie--spell)))
        (genie--learn-spell
         "(defun genie-spell/twice () (interactive) 'second)")
        ;; the captured function object of the old entry is unaffected
        (should (eq (funcall old) 'first))
        (should (eq (funcall (genie--spell-fn genie--spell)) 'second))
        (should (equal (mapcar #'car (genie--spell-labels))
                       '("genie-spell/twice" "genie-spell/twice<2>")))))))

;;;; genie: unified undo journal

(ert-deftest genie-undo-cast-effect ()
  "A journaled cast is undone by `genie-undo' in the buffer it edited."
  (let ((genie--journal nil) (genie--state 'idle))
    (with-temp-buffer
      (buffer-enable-undo)
      (insert "hello\nworld\n")
      (undo-boundary)
      (genie-live-call
       'test (lambda () (interactive) (upcase-region (point-min) (point-max))))
      (should (equal (buffer-string) "HELLO\nWORLD\n"))
      (should (eq (caar genie--journal) 'cast))
      (genie-undo)
      (should (equal (buffer-string) "hello\nworld\n"))
      (should-not genie--journal))))

(ert-deftest genie-undo-cast-survives-truncated-history ()
  "GC dropping the pre-cast tail must not strand the journal entry.
When nothing changed since the cast, its groups are the list head and
are undone whole even though the recorded tail is gone."
  (let ((genie--journal nil) (genie--state 'idle))
    (with-temp-buffer
      (buffer-enable-undo)
      (insert "aged history\n")
      (undo-boundary)
      (genie-live-call
       'test (lambda () (interactive) (upcase-region (point-min) (point-max))))
      (should (equal (buffer-string) "AGED HISTORY\n"))
      ;; emulate truncate_undo_list: cut the tail in place, head cons intact
      (pcase-let ((`(cast ,_ ,pre ,_ ,_) (car genie--journal)))
        (let ((cons buffer-undo-list))
          (while (not (eq (cdr cons) pre)) (setq cons (cdr cons)))
          (setcdr cons nil)))
      (genie-undo)
      (should (equal (buffer-string) "aged history\n"))
      (should-not genie--journal))))

(ert-deftest genie-undo-cast-tolerates-rebuilt-history ()
  "A rebuilt undo list (buffer revert) drops the entry with a message.
The effect is gone with the revert; undo must not error or strand it."
  (let ((genie--journal nil) (genie--state 'idle))
    (with-temp-buffer
      (buffer-enable-undo)
      (insert "x\n")
      (undo-boundary)
      (genie-live-call
       'test (lambda () (interactive) (upcase-region (point-min) (point-max))))
      (setq buffer-undo-list '(nil))    ; what a revert leaves behind
      (genie-undo)                      ; no error, entry consumed
      (should-not genie--journal))))

(ert-deftest genie-undo-empty-journal-message ()
  "With an empty journal and a foreign HEAD, undo explains itself."
  (genie-tests--with-repo
    (genie-tests--write "a.el" "(setq a 1)\n")
    (genie--git "add" "-A")
    (genie--git "commit" "-qm" "base")
    (let ((err (should-error (genie-undo) :type 'user-error)))
      (should (string-match-p "journal is empty" (cadr err))))))

(ert-deftest genie-journal-skips-effectless-casts ()
  "A cast that edits nothing leaves no journal entry."
  (let ((genie--journal nil))
    (with-temp-buffer
      (buffer-enable-undo)
      (genie-live-call 'noop (lambda () (interactive) 'noop))
      (should-not genie--journal))))

(ert-deftest genie-cantrip-pipeline ()
  "A cantrip turn executes immediately on the captured region and is undoable."
  (let ((genie--spell nil) (genie--spells nil)
        (genie--state 'idle) (genie--changed nil) (genie--journal nil)
        (genie--pending-register nil))
    (with-temp-buffer
      (buffer-enable-undo)
      (insert "alpha\nbeta\n")
      (undo-boundary)
      (setq genie--cantrip-target
            (list :buffer (current-buffer) :point (point-marker)
                  :region (cons (copy-marker (point-min))
                                (copy-marker (point-max)))))
      (genie-tests--conjuring
        (genie--conjure "upcase it" "cantrip: upcase it" t)
        (genie-tests--conjured
         (concat "```elisp\n"
                 "(defun genie-spell/upcase-it (beg end)\n"
                 "  \"Upcase the region.\"\n"
                 "  (interactive \"r\")\n"
                 "  (upcase-region beg end))\n"
                 "```")))
      (should (equal (buffer-string) "ALPHA\nBETA\n"))
      (should (eq (genie--spell-name genie--spell) 'genie-spell/upcase-it))
      (should (eq (caar genie--journal) 'cast))
      (should (eq genie--state 'idle))
      (genie-undo)
      (should (equal (buffer-string) "alpha\nbeta\n")))))

;;;; genie-wish: wishes that can be taken back

(defvar genie-tests--map (make-sparse-keymap) "A keymap for wishes to bind in.")
(defvar genie-tests--hook nil "A hook for wishes to add to.")
(defvar genie-tests--list '(a) "A list for wishes to add to.")
(defvar genie-tests--option 1 "An option for wishes to set.")
(defvar genie-tests--effect nil "What a bare effect did.")
(define-minor-mode genie-tests-mode "A mode for wishes to switch." :global t)
(defun genie-tests--advice (&rest _) "An advice for wishes to add." nil)
(defun genie-tests--advised () "A function for wishes to advise." nil)

(defmacro genie-tests--with-wishes (&rest body)
  "Run BODY with no wishes defined and a throwaway directory to keep them in."
  (declare (indent 0))
  `(let ((genie-wish--all nil)
         (genie-wish-directory (make-temp-file "genie-tests-wishes" t))
         (warning-suppress-log-types '((genie))))
     (unwind-protect (progn ,@body)
       (dolist (wish (genie-wish-list))
         (genie-wish-off (plist-get wish :name)))
       (delete-directory genie-wish-directory t))))

(defun genie-tests--state ()
  "Return everything the test wishes may have changed."
  (list (lookup-key genie-tests--map (kbd "C-c d")) genie-tests--option
        genie-tests--hook genie-tests-mode genie-tests--list
        (and (advice-member-p #'genie-tests--advice 'genie-tests--advised) t)
        genie-tests--effect))

(ert-deftest genie-wish-every-effect-is-taken-back ()
  "Switching a wish off puts each thing it changed back as it was."
  (genie-tests--with-wishes
    (define-key genie-tests--map (kbd "C-c d") #'ignore)
    (let ((before (genie-tests--state)) timer)
      (genie-wish everything
        "Change one of everything."
        (genie-key genie-tests--map "C-c d" #'forward-char)
        (genie-set 'genie-tests--option 5)
        (genie-hook 'genie-tests--hook #'ignore)
        (genie-enable 'genie-tests-mode)
        (genie-add 'genie-tests--list 'b)
        (genie-advice 'genie-tests--advised :before #'genie-tests--advice)
        (setq timer (genie-timer (run-at-time 3600 nil #'ignore)))
        (genie-effect "a flag" (lambda () (setq genie-tests--effect t))
                      (lambda () (setq genie-tests--effect nil))))
      (should (equal (genie-tests--state)
                     '(forward-char 5 (ignore) t (b a) t t)))
      (should (memq timer timer-list))
      (should (equal (plist-get (car (genie-wish-list)) :state) 'on))
      (should (member "key C-c d runs forward-char"
                      (plist-get (car (genie-wish-list)) :effects)))
      (genie-wish-off 'everything)
      (should (equal (genie-tests--state) before))
      (should-not (memq timer timer-list))
      (should-not (plist-get (car (genie-wish-list)) :effects))
      ;; on again, then defined anew: the old definition's changes go first
      (genie-wish-on 'everything)
      (should (= genie-tests--option 5))
      (genie-wish everything "Only the option now."
        (genie-set 'genie-tests--option 9))
      (should (equal (genie-tests--state)
                     (cons (car before) (cons 9 (cddr before)))))
      (should (= (length (genie-wish-list)) 1)))))

(ert-deftest genie-wish-one-that-signals-is-switched-off-whole ()
  "A wish that fails halfway leaves nothing of itself, and says why."
  (genie-tests--with-wishes
    (genie-wish halfway "Fail after the first change."
      (genie-set 'genie-tests--option 5)
      (error "No such thing"))
    (should (= genie-tests--option 1))
    (let ((wish (car (genie-wish-list))))
      (should (eq (plist-get wish :state) 'broken))
      (should (equal (plist-get wish :error) "No such thing")))
    ;; and an effect has nowhere to be remembered outside a wish
    (should-error (genie-set 'genie-tests--option 5))))

(ert-deftest genie-wish-a-deferred-part-waits-and-respects-off ()
  "What waits for a library runs when it loads, unless the wish is off by then."
  (genie-tests--with-wishes
    (let ((soon (intern (format "genie-tests-soon-%d" (random 100000))))
          (late (intern (format "genie-tests-late-%d" (random 100000)))))
      (genie-wish patient "Wait for two libraries."
        (genie-after 'subr-x (genie-add 'genie-tests--list 'now))
        (genie-after soon (genie-set 'genie-tests--option 5))
        (genie-after late (genie-add 'genie-tests--list 'never)))
      (should (memq 'now genie-tests--list)) ; already loaded: at once
      (should (= genie-tests--option 1))
      (provide soon)
      (should (= genie-tests--option 5))
      (genie-wish-off 'patient)
      (should (= genie-tests--option 1))     ; the deferred part is undone too
      (provide late)
      (should-not (memq 'never genie-tests--list)))))

(ert-deftest genie-wish-files-load-on-their-own-and-kept-off-stays-off ()
  "A directory of wishes starts whatever one file does; off is remembered."
  (genie-tests--with-wishes
    (cl-flet ((write (name content)
                (with-temp-file (expand-file-name name genie-wish-directory)
                  (insert content))))
      (write "a-broken.el" "(genie-wish broken-file \"x\" (genie-set")
      (write "b-good.el"
             "(genie-wish good \"Set the option.\" (genie-set 'genie-tests--option 5))")
      (write "c-quiet.el"
             "(genie-wish quiet \"Add to the list.\" (genie-add 'genie-tests--list 'q))"))
    (genie-wish-load)
    (should (= genie-tests--option 5))
    (should (memq 'q genie-tests--list))
    (genie-wish-keep 'quiet nil)
    (should-not (memq 'q genie-tests--list))
    (should (equal (genie-wish-disabled) '(quiet)))
    ;; a new session: the same files, the same choice
    (genie-wish-off 'good)
    (setq genie-wish--all nil)
    (genie-wish-load)
    (should (= genie-tests--option 5))
    (should-not (memq 'q genie-tests--list))
    (should (eq (plist-get (cadr (genie-wish-list)) :state) 'off))
    (genie-wish-keep 'quiet t)
    (should (memq 'q genie-tests--list))
    (should-not (genie-wish-disabled))))

(ert-deftest genie-wish-a-mode-hook-holds-for-what-is-already-open ()
  "A wish on a mode's hook reaches the open buffers, and leaves them again."
  (genie-tests--with-wishes
    (let ((code (generate-new-buffer "genie-tests.el"))
          (text (generate-new-buffer "genie-tests.txt")))
      (unwind-protect
          (progn
            (with-current-buffer code (delay-mode-hooks (emacs-lisp-mode)))
            (with-current-buffer text (delay-mode-hooks (text-mode)))
            (genie-wish numbers "Number the lines of programs."
              (genie-hook 'prog-mode-hook #'display-line-numbers-mode))
            (should (buffer-local-value 'display-line-numbers-mode code))
            (should-not (buffer-local-value 'display-line-numbers-mode text))
            (genie-wish-off 'numbers)
            (should-not (buffer-local-value 'display-line-numbers-mode code))
            (should-not (memq #'display-line-numbers-mode prog-mode-hook)))
        (kill-buffer code)
        (kill-buffer text)))))

;;;; genie-pipeline: a wish file is accepted only if it can be taken back

(ert-deftest genie-lint-names-what-could-not-be-taken-back ()
  "A change made where it stands is refused; the same inside a function is not."
  (cl-flet ((problems (form) (genie--irreversible-in form)))
    (should (string-match-p "genie-hook" (car (problems '(add-hook 'a #'b)))))
    (should (string-match-p "genie-set"
                            (car (problems '(genie-wish w "d" (setq a 1))))))
    (should (string-match-p "genie-key"
                            (car (problems '(genie-wish w "d"
                                              (genie-after 'org
                                                (define-key m "a" #'b)))))))
    (should (string-match-p "genie-enable" (car (problems '(vertico-mode 1)))))
    (should (string-match-p ":bind"
                            (car (problems '(use-package magit :ensure t
                                              :bind ("C-x g" . magit))))))
    (should-not (problems '(use-package magit :ensure t :defer t)))
    (should-not (problems '(defun f () (add-hook 'a #'b nil t) (setq x 1))))
    (should-not (problems '(genie-wish w "d"
                             (genie-key global-map "C-c d" #'f)
                             (genie-timer (run-at-time 1 nil #'f)))))))

(ert-deftest genie-validation-refuses-a-wish-with-no-way-back ()
  "The refusal reaches the agent as a verdict, before anything is loaded."
  (genie-tests--with-repo
    (genie-tests--write "wishes/slow.el"
                        "(add-hook 'post-command-hook #'ignore)\n")
    (genie-tests--write "mod.el" "(add-hook 'x #'ignore)\n")
    (let ((genie--changed '("wishes/slow.el" "mod.el")) verdict)
      (genie--validate (lambda (it) (setq verdict it)))
      (should-not (car verdict))
      (should (string-match-p "wishes/slow.el: `add-hook'.*genie-hook"
                              (cdr verdict)))
      ;; outside the wishes nothing is asked of old code — but a hook that
      ;; runs on every key is named wherever it is
      (should-not (string-match-p "mod.el" (cdr verdict)))
      (should (equal genie--cautions '(post-command-hook))))))

(ert-deftest genie-batch-validation-fails-a-wish-that-would-not-start ()
  "A wish that signals at startup fails validation with its own words."
  (genie-tests--with-repo
    (genie-tests--write
     "init.el"
     (format "(setq genie-wish-directory %S)\n(require 'genie-wish)\n(genie-wish-load)\n"
             genie-wish-directory))
    (genie-tests--write "wishes/bad.el"
                        "(genie-wish bad \"x\" (error \"Not today\"))\n")
    (let ((genie--changed '("wishes/bad.el")) (genie-validate 'batch) verdict)
      (genie--validate (lambda (it) (setq verdict it)))
      (with-timeout (30 (error "Validation never answered"))
        (while (not verdict) (accept-process-output nil 0.05)))
      (should-not (car verdict))
      (should (string-match-p "Not today" (cdr verdict))))))

(ert-deftest genie-refresh-follows-the-wish-files ()
  "A wish file that changed is live at once; one that is gone is taken back."
  (genie-tests--with-repo
    (genie-tests--write
     "wishes/five.el"
     "(genie-wish five \"Five.\" (genie-set 'genie-tests--option 5))\n")
    (genie--refresh '("wishes/five.el"))
    (should (= genie-tests--option 5))
    (genie-tests--write
     "wishes/five.el"
     "(genie-wish five \"Seven now.\" (genie-set 'genie-tests--option 7))\n")
    (genie--refresh '("wishes/five.el"))
    (should (= genie-tests--option 7))
    (delete-file (expand-file-name "wishes/five.el" (genie--root)))
    (genie--refresh '("wishes/five.el"))
    (should (= genie-tests--option 1))
    (should-not (genie-wish-list))))

;;;; genie-lamp

(ert-deftest genie-lamp-switches-a-wish-off-as-a-commit-undo-takes-back ()
  "Off in the lamp is off now, kept, committed — and undone like a wish."
  (genie-tests--with-repo
    (genie-tests--write
     "wishes/five.el"
     "(genie-wish five \"Five.\" (genie-set 'genie-tests--option 5))\n")
    (genie--git "add" "-A")
    (genie--git "commit" "-q" "-m" "genie: five")
    (genie--refresh '("wishes/five.el"))
    (save-window-excursion
      (genie-lamp)
      (set-buffer "*genie lamp*")
      (goto-char (point-min))
      (should (string-match-p "● +five +Five\\." (buffer-string)))
      (genie-lamp-toggle)
      (should (= genie-tests--option 1))
      (should (string-match-p "○ +five" (buffer-string)))
      (kill-buffer))
    (should (equal (genie--git "log" "-1" "--format=%s") "genie: switch five off"))
    (should (equal (genie-wish-disabled) '(five)))
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t)))
      (genie-undo))
    (should (= genie-tests--option 5))
    (should-not (genie-wish-disabled))
    (genie-wish-off 'five)))

;;;; genie-tools and genie-live: Emacs as the agent's tools

(ert-deftest genie-acp-serves-emacs-as-tools-over-the-connection ()
  "A session with tools names Emacs as its server, lists them and calls them."
  (genie-tests--with-agent agent sent
    (let* ((tool (list :name "echo" :description "Say it back."
                       :schema '(:type "object")
                       :call (lambda (args say)
                               (if (plist-get args :fail)
                                   (error "Would not")
                                 (funcall say (plist-get args :text))))))
           (session (genie-acp-open agent "/tmp/project/" :tools (list tool))))
      (genie-acp-ensure session #'ignore)
      (genie-tests--answer agent 1 '(:protocolVersion 1))
      (should (equal (plist-get (plist-get (car sent) :params) :mcpServers)
                     [(:type "acp" :name "emacs" :serverId "emacs-0")]))
      (cl-flet ((ask (id method params)
                  (genie-tests--say
                   agent (list :jsonrpc "2.0" :id id :method "mcp/message"
                               :params (list :serverId "emacs-0" :requestId "r"
                                             :method method :params params)))
                  (plist-get (car sent) :result)))
        (should (equal (plist-get (aref (plist-get (plist-get (ask "a" "tools/list" nil)
                                                               :result)
                                                    :tools)
                                         0)
                                   :name)
                       "echo"))
        (let ((said (plist-get (ask "b" "tools/call"
                                    '(:name "echo" :arguments (:text "hello")))
                               :result)))
          (should (equal (plist-get (aref (plist-get said :content) 0) :text)
                         "hello"))
          (should (eq (plist-get said :isError) :false)))
        (should (eq (plist-get (plist-get (ask "c" "tools/call"
                                               '(:name "echo" :arguments (:fail t)))
                                          :result)
                               :isError)
                    t))
        (should (plist-get (ask "d" "tools/call" '(:name "nope")) :error))))))

(ert-deftest genie-acp-a-long-line-in-pieces-is-one-message ()
  "Pieces with no newline are only kept; the line is read once it ends."
  (genie-tests--with-agent agent sent
    (let (got)
      (cl-letf (((symbol-function 'genie-acp--dispatch)
                 (lambda (_agent message) (push message got))))
        (genie-acp--filter agent "{\"a\":")
        (genie-acp--filter agent "\"")
        (genie-acp--filter agent (make-string 5000 ?x))
        (should-not got)
        (genie-acp--filter agent "\"}\n{\"b\":1}\n{\"c\"")
        (should (= (length got) 2))
        (should (= (length (plist-get (cadr got) :a)) 5000))
        (genie-acp--filter agent ":2}\n")
        (should (equal (car got) '(:c 2)))))))

(ert-deftest genie-tools-ask-the-running-emacs ()
  "The asking tools answer from this session, and say so when there is nothing."
  (should (string-match-p "forward-char is a command"
                          (genie-tools--describe '(:symbol "forward-char"))))
  (should (string-match-p "genie-tests--option is a variable.*\nValue: 1"
                          (genie-tools--describe '(:symbol "genie-tests--option"))))
  (should (string-match-p "apropos"
                          (genie-tools--describe '(:symbol "genie-tests-no-such"))))
  (should (string-match-p "command genie-lamp — "
                          (genie-tools--apropos '(:pattern "^genie-lamp$"))))
  (should (string-match-p "(defun genie-tools--clip"
                          (genie-tools--source '(:symbol "genie-tools--clip"))))
  (should (<= (length (genie-tools--clip (make-string 9000 ?x))) 6010)))

(ert-deftest genie-tools-eval-acts-where-the-wish-was-made ()
  "Code runs in the buffer asked from, on its region, and undo takes it back."
  (let ((genie--journal nil) (genie--state 'idle) (genie-confirm nil))
    (with-temp-buffer
      (buffer-enable-undo)
      (insert "hello world")
      (undo-boundary)
      (set-mark 1) (goto-char 6) (activate-mark)
      (let ((transient-mark-mode t)) (genie-live-remember-place))
      (deactivate-mark)
      (let ((target (current-buffer)))
        (with-temp-buffer             ; the agent's call arrives elsewhere
          (should (string-match-p
                   "=> \"HELLO\"\n(ran in buffer"
                   (genie-tools--eval
                    '(:code "(upcase-region (region-beginning) (region-end))
(buffer-substring (region-beginning) (region-end))"))))
          (should (equal (with-current-buffer target (buffer-string))
                         "HELLO world"))))
      (should (eq (caar genie--journal) 'cast))
      (genie-undo)
      (should (equal (buffer-string) "hello world")))))

(ert-deftest genie-tools-eval-is-screened-and-never-runs-in-the-filter ()
  "Risky code a person declines is not run; a tool call only schedules."
  (let ((genie-confirm '(risky-code)) (genie-live--place nil))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) nil)))
      (should-error (genie-tools--eval '(:code "(delete-file \"/nope\")")))))
  (let ((tool (cl-find "eval" genie-tools :test #'equal
                       :key (lambda (tool) (plist-get tool :name))))
        scheduled said)
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (_time _repeat function &rest args)
                 (push (lambda () (apply function args)) scheduled))))
      (funcall (plist-get tool :call) '(:code "(+ 1 2)")
               (lambda (text &optional failed) (setq said (list text failed))))
      (should-not said)                 ; nothing ran on the caller's stack
      (let ((genie-live--place nil)) (funcall (car scheduled))))
    (should (string-match-p "=> 3" (car said)))
    (should-not (cadr said))))

;;;; genie: one way in

(ert-deftest genie-a-wish-says-where-it-was-made ()
  "The wish carries the buffer and the region; the commit keeps only the wish."
  (genie-tests--with-repo
    (let (sent)
      (cl-letf (((symbol-function 'genie-chat-submit)
                 (lambda (_buffer text shown)
                   (setq sent (append sent (list text shown)))))
                ((symbol-function 'genie-chat-attach)
                 (lambda (_buffer label _block) (push label sent))))
        (unwind-protect
            (with-temp-buffer
              (insert "some text")
              (set-mark 1) (goto-char 5)
              (let ((transient-mark-mode t) (mark-active t))
                (genie "make this louder"))
              (should (eq (plist-get genie-live--place :buffer) (current-buffer)))
              (should (plist-get genie-live--place :region)))
          (genie--cleanup)))
      (should (string-match-p "1-1\\'" (car sent)))   ; the region went along
      (should (string-match-p "\\`make this louder\n\n\\[Asked from the buffer"
                              (cadr sent)))
      (should (equal (caddr sent) "make this louder")))))

(ert-deftest genie-setup-adds-only-what-is-missing ()
  "Setup has init.el load the wishes and grants the keys, once."
  (genie-tests--with-repo
    (genie-tests--write "init.el" ";;; mine\n(setq my-thing 1)\n")
    (let ((bound (lookup-key global-map (kbd "C-c g"))))
      (unwind-protect
          (progn
            ;; a wish with nowhere to be kept would be gone at restart
            (delete-directory genie-wish-directory t)
            (should-error (genie--turn-starting "a wish") :type 'user-error)
            (genie-setup)
            (should (string-match-p
                     "(setq my-thing 1)\n\n;; Wishes granted.*\n(setq genie-wish-directory\n.*\n(require 'genie-wish)\n(genie-wish-load)\n\\'"
                     (genie-tests--read "init.el")))
            (should (eq (lookup-key global-map (kbd "C-c g")) 'genie-command-map))
            (should (equal (genie--git "log" "-1" "--format=%s") "genie: setup"))
            (genie-setup)
            (should (equal (genie--git "rev-list" "--count" "HEAD") "1"))
            ;; and panic takes even that back, for the session
            (cl-letf (((symbol-function 'genie--cleanup) #'ignore))
              (genie-panic))
            (should (equal (lookup-key global-map (kbd "C-c g")) bound)))
        (define-key global-map (kbd "C-c g") bound)))))

(ert-deftest genie-a-spell-cast-a-third-time-offers-to-stay ()
  "Repetition is the sign a one-off wants to be kept."
  (let ((genie--journal nil) (genie--casts (make-hash-table :test #'eq))
        (entry (list 'genie-spell/thrice (lambda () (interactive) nil) ""))
        said)
    (cl-letf (((symbol-function 'message)
               (lambda (format &rest args) (push (apply #'format format args) said))))
      (dotimes (_ 4) (genie--cast entry)))
    (should (= (length said) 1))
    (should (string-match-p "genie-spell-keep" (car said)))))


(provide 'genie-tests)
;;; genie-tests.el ends here
