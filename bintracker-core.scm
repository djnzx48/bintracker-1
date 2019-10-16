;; -*- geiser-scheme-implementation: 'chicken -*-

;; This file is part of Bintracker NG.
;; Copyright (c) utz/irrlicht project 2019
;; See LICENSE for license details.

(module bintracker-core
    *

  (import scheme (chicken base) (chicken platform) (chicken string)
	  (chicken module) (chicken io) (chicken bitwise) (chicken format)
	  srfi-1 srfi-13 srfi-69 pstk defstruct matchable list-utils
	  simple-exceptions mdal bt-state bt-types bt-gui)
  ;; all symbols that are required in generated code (mdal compiler generator)
  ;; must be re-exported
  (reexport mdal pstk bt-types bt-state bt-gui (chicken bitwise)
	    srfi-1 srfi-13 list-utils simple-exceptions)


  ;; ---------------------------------------------------------------------------
  ;;; ## Global Actions
  ;; ---------------------------------------------------------------------------

  ;;; load the main configuration file
  (define (load-config)
    (handle-exceptions
	exn
	(begin
	  (display exn)
	  (newline))
      (load "config/config.scm")))

  ;;; If there are unsaved changes to the current module, ask user if they
  ;;; should be saved, then execute the procedure {{proc}} unless the user
  ;;; cancelled the action. With no unsaved changes, simply execute {{proc}}.
  (define (do-proc-with-exit-dialogue dialogue-string proc)
    (if (state 'modified)
	(match (exit-with-unsaved-changes-dialog dialogue-string)
	  ("yes" (begin (save-file)
			(proc)))
	  ("no" (proc))
	  (else #f))
	(proc)))

  (define (exit-bintracker)
    (do-proc-with-exit-dialogue "exit" tk-end))

  (define on-close-file-hooks
    (list (lambda () (destroy-group-widget (state 'module-widget)))
	  (lambda () (set-play-buttons 'disabled))
	  reset-state! update-window-title! reset-status-text!))

  ;; TODO disable menu option
  (define (close-file)
    (when (current-mod)
      (do-proc-with-exit-dialogue
       "closing"
       (lambda () (execute-hooks on-close-file-hooks)))))

  (define after-load-file-hooks
    (list (lambda ()
	    (set-state! 'module-widget (make-module-widget main-frame)))
	  (lambda () (set-play-buttons 'enabled))
	  show-module reset-status-text! update-window-title!
	  (lambda () (focus-metatree (current-blocks-view)))))

  (define (load-file)
    (let ((filename (tk/get-open-file
		     filetypes: '{{{MDAL Modules} {.mdal}} {{All Files} *}})))
      (unless (string-null? filename)
	(begin (console 'insert 'end
			(string-append "\nLoading file: " filename "\n"))
	       (handle-exceptions
		   exn
		   (console 'insert 'end
			    (string-append "\nError: " (->string exn)
					   "\n" (message exn)))
		 (set-current-mod! filename)
		 (set-state! 'current-file filename)
		 (execute-hooks after-load-file-hooks))))))

  (define on-save-file-hooks
    (list (lambda () (md:module->file (current-mod) (state 'current-file)))
	  (lambda () (set-state! 'modified #f))
	  update-window-title!))

  (define (save-file)
    (if (state 'current-file)
	(execute-hooks on-save-file-hooks)
	(save-file-as)))

  (define (save-file-as)
    (let ((filename (tk/get-save-file
		     filetypes: '(((MDAL Modules) (.mdal)))
		     defaultextension: '.mdal)))
      (unless (string-null? filename)
	(set-state! 'current-file filename)
	(execute-hooks on-save-file-hooks))))

  (define (launch-help)
    ;; TODO windows untested
    (let ((uri (cond-expand
		 (unix "\"documentation/index.html\"")
		 (windows "\"documentation\\index.html\"")))
	  (open-cmd (cond-expand
		      ((or linux freebsd netbsd openbsd) "xdg-open ")
		      (macosx "open ")
		      (windows "[list {*}[auto_execok start] {}] "))))
      (tk-eval (string-append "exec {*}" open-cmd uri " &"))))

  (define (eval-console)
    (handle-exceptions
	exn
	(console 'insert 'end
			(string-append "\nError: " (->string exn)
				       (->string (arguments exn))))
      (let ((input-str (console 'get "end-1l" "end-1c")))
	(when (not (string-null? input-str))
	  (console 'insert 'end
			  (string-append
			   "\n"
			   (->string
			    (eval (read (open-input-string input-str))))))))))


  ;; ---------------------------------------------------------------------------
  ;;; ## Main Menu
  ;; ---------------------------------------------------------------------------

  (define (init-main-menu)
    (set-state!
     'menu (construct-menu
	    (map (lambda (item) (cons 'submenu item))
		 `((file "File" 0 ((command new "New..." 0 "Ctrl+N" #f)
				   (command open "Open..." 0 "Ctrl+O"
					    ,load-file)
				   (command save "Save" 0 "Ctrl+S" ,save-file)
				   (command save-as "Save as..." 5
					    "Ctrl+Shift+S" ,save-file-as)
				   (command close "Close" 0 "Ctrl+W"
					    ,close-file)
				   (separator)
				   (command exit "Exit" 1 "Ctrl+Q"
					    ,exit-bintracker)))
		   (edit "Edit" 0 ())
		   (generate "Generate" 0 ())
		   (transform "Transform" 0 ())
		   (help "Help" 0 ((command launch-help "Help" 0 "F1"
					    ,launch-help)
				   (command about "About" 0 #f
					    ,about-message))))))))


  ;; ---------------------------------------------------------------------------
  ;;; ## Toolbar
  ;; ---------------------------------------------------------------------------

  ;;; Create a toolbar button widget. This also binds the mouse <Enter>/<Leave>
  ;;; events to display {{description}} in the status bar.
  (define (toolbar-button icon command key-action description
  			  #!optional (init-state 'disabled))
    (let ((button-widget
  	   (toolbar-frame 'create-widget 'button image: (tk/icon icon)
  			  state: init-state command: command
  			  style: "Toolbutton")))
      (bind-info-status button-widget
			(string-append description " "
				       (key-binding->info 'global key-action)))
      button-widget))

  (define toolbar-button-groups
    `((file (new ,(toolbar-button "new.png" (lambda () #t)
				  'create-new-file "New File" 'enabled))
	    (load ,(toolbar-button "load.png" load-file 'load-file
				   "Load File..." 'enabled))
	    (save ,(toolbar-button "save.png" save-file 'save-file
				   "Save File")))
      (edit (copy ,(toolbar-button "copy.png" (lambda () #t)
      				   'copy "Copy Selection"))
      	    (cut ,(toolbar-button "cut.png" (lambda () #t)
      				  'cut "Cut Selection (delete with shift)"))
      	    (clear ,(toolbar-button "clear.png" (lambda () #t)
      				    'clear
				    "Clear Selection (delete, no shift)"))
      	    (paste ,(toolbar-button "paste.png" (lambda () #t)
      				    'paste "Paste from Clipboard (no shift)"))
      	    (insert ,(toolbar-button "insert.png" (lambda () #t)
      				     'insert
				     "Insert from Clipbard (with shift)"))
      	    (swap ,(toolbar-button "swap.png" (lambda () #t)
      				   'swap "Swap Selection with Clipboard")))
      (play (stop ,(toolbar-button "stop.png" (lambda () #t)
      				   'stop "Stop Playback"))
      	    (play ,(toolbar-button "play.png" (lambda () #t)
      				   'play "Play Track from Current Position"))
      	    (play-from-start ,(toolbar-button "play-from-start.png"
      					      (lambda () #t)
      					      'play-from-start
					      "Play Track from Start"))
      	    (play-pattern ,(toolbar-button "play-ptn.png" (lambda () #t)
      					   'play-pattern "Play Pattern")))
      (configure (prompt ,(toolbar-button "prompt.png" (lambda () #t)
      					  'toggle-prompt "Toggle Console"
					  'enabled))
      		 (settings ,(toolbar-button "settings.png" (lambda () #t)
      					    'show-settings "Settings..."
					    'enabled)))))

  ;;; construct and display the main toolbar
  (define (make-toolbar)
    (for-each (lambda (button-group)
  		(for-each (lambda (button)
  			    (tk/pack button side: 'left padx: 0 fill: 'y))
  			  (map cadr (cdr button-group)))
  		(tk/pack (toolbar-frame 'create-widget 'separator
  					orient: 'vertical)
  			 side: 'left padx: 0 'fill: 'y))
  	      toolbar-button-groups))

  ;;; Set the state of the play button. {{state}} must be either `'enabled` or
  ;;; `'disabled`.
  (define (set-play-buttons state)
    (for-each (lambda (button)
		((cadr button) 'configure state: state))
	      (alist-ref 'play toolbar-button-groups)))

  ;; ---------------------------------------------------------------------------
  ;;; ## Key Bindings
  ;; ---------------------------------------------------------------------------

  (define (update-key-bindings!)
    (for-each (lambda (group widget)
		(for-each (lambda (key-mapping)
			    (tk/bind widget (car key-mapping)
				     (eval (cadr key-mapping))))
			  (get-keybinding-group group)))
	      '(global console)
	      (list tk console)))


  ;; ---------------------------------------------------------------------------
  ;;; ## Hooks
  ;; ---------------------------------------------------------------------------

  (define on-startup-hooks
    (list load-config update-window-title! patch-tcltk-8.6.9-treeview
	  update-style! init-main-menu
	  (lambda ()
	    (when (settings 'show-menu)
	      (tk 'configure 'menu: (menu-widget (state 'menu)))))
	  init-top-level-layout
	  (lambda ()
	    (when (app-settings-show-toolbar *bintracker-settings*)
	      (make-toolbar)))
	  init-console init-status-bar disable-keyboard-traversal
	  update-key-bindings!))

  (define (execute-hooks hooks)
    (for-each (lambda (hook)
		(hook))
	      hooks))


  ;; ---------------------------------------------------------------------------
  ;;; ## Startup Procedure
  ;; ---------------------------------------------------------------------------

  ;;; WARNING: YOU ARE LEAVING THE FUNCTIONAL SECTOR!

  (execute-hooks on-startup-hooks)

  ;; ---------------------------------------------------------------------------
  ;;; ## Main Loop
  ;; ---------------------------------------------------------------------------

  (tk-event-loop)

  ) ;; end module bintracker
