;; This file is part of the libmdal library.
;; Copyright (c) utz/irrlicht project 2018-2020
;; See LICENSE for license details.

(module mdal *

  (import scheme (chicken base) (chicken module) (chicken pretty-print)
	  (chicken format) (chicken string) (chicken bitwise) (chicken sort)
	  srfi-1 srfi-4 srfi-13 srfi-69 typed-records
	  (only list-utils list-copy* list-set!)
	  md-config md-helpers md-types md-parser)
  (reexport md-config md-helpers md-types md-parser)

  (define-constant mdal-version 2)

  ;;----------------------------------------------------------------------------
  ;;; ### Output generation
  ;;----------------------------------------------------------------------------

  (define (mod-block-instance-contents->expr block-id contents mdconfig)
    (letrec
	((field-ids (config-get-subnode-ids block-id
					    (config-itree mdconfig)))
	 (collapse-empty-rows
	  (lambda (rows)
	    (if (null? rows)
		'()
		(let ((empty-head (length (take-while null? rows))))
		  (if (zero? empty-head)
		      (append (take-while pair? rows)
			      (collapse-empty-rows (drop-while pair? rows)))
		      (cons empty-head
			    (collapse-empty-rows (drop rows empty-head)))))))))
      (collapse-empty-rows
       (map (lambda (row)
	      (cond
	       ((= (length field-ids) (length (remove null? row))) row)
	       ((null-list? (remove null? row)) '())
	       (else (filter-map (lambda (field-id field-val)
				   (and (not (null? field-val))
					(list field-id field-val)))
				 field-ids row))))
	    contents))))

  (define (mod-node->node-expr node-id node-contents mdconfig)
    (map (cute mod-node-instance->instance-expr node-id <> mdconfig)
	 node-contents))

  (define (mod-group-instance-contents->node-expr group-id contents mdconfig)
    (letrec ((resolve-nesting (lambda (subnode)
				(if (null? subnode)
				    '()
				    (append (car subnode)
					    (resolve-nesting (cdr subnode)))))))
      (resolve-nesting
	   (filter-map (lambda (node-id)
			 (let ((node-expr (mod-node->node-expr
					   node-id (alist-ref node-id contents)
					   mdconfig)))
			   (and (pair? node-expr)
				node-expr)))
		       (config-get-subnode-ids group-id
					       (config-itree mdconfig))))))

  (define (mod-node-instance->instance-expr node-id instance mdconfig)
    (cons (if (symbol-contains node-id "_ORDER")
	      'ORDER node-id)
	  (append (if (not (zero? (car instance)))
		      (list 'id: (car instance))
		      '())
		  (if (cadr instance)
		      (list 'name: (cadr instance))
		      '())
		  (case (inode-config-type (config-inode-ref node-id mdconfig))
		    ((field) (list (cddr instance)))
		    ((block) (mod-block-instance-contents->expr
			      node-id (cddr instance) mdconfig))
		    ((group) (mod-group-instance-contents->node-expr
			      node-id (cddr instance) mdconfig))))))

  ;;; Write the MDAL module MOD to an .mdal file.
  (define (mdmod->file mod filename)
    (call-with-output-file filename
      (lambda (port)
	(pp (append (list 'mdal-module 'version: mdal-version
			  'config: (mdmod-config-id mod)
			  'config-version:
			  (plugin-version->real
			   (config-plugin-version (car mod))))
		    (mod-group-instance-contents->node-expr
		     'GLOBAL (cddr (cadr (mdmod-global-node mod)))
		     (mdmod-config mod)))
	    port))))

  ;; TODO and a list of symbols for mod->asm?
  ;;; Compile a module to an onode tree.
  (define (mod-compile mod origin #!optional (extra-symbols '()))
    ((config-compiler (mdmod-config mod))
     mod origin (cons `(mdal_current_module ,mod)
		      extra-symbols)))

  ;;; Compile a module into a list of byte values.
  (define (mod->bin mod origin #!optional (extra-symbols '()))
    (flatten (map onode-val
		  (remove (lambda (onode)
			    (memq (onode-type onode)
				  '(comment symbol)))
			  (mod-compile mod origin extra-symbols)))))

  ;;; Compile an module into an assembly source
  (define (mod->asm mod origin extra-symbols)
    (let ((otree (mod-compile mod origin #!optional extra-symbols)))
      '()))

  ;;; Compile the given module to a binary file.
  (define (mod-export-bin filename mod origin)
    (call-with-output-file filename
      (lambda (port)
	(write-u8vector (list->u8vector (mod->bin mod origin))
			port))))

  ;; ---------------------------------------------------------------------------
  ;;; ### Additional accessors
  ;; ---------------------------------------------------------------------------

  ;;; Returns the group instance's block nodes, except the order node. The
  ;;; order node can be retrieved with `mod-get-group-instance-order` instead.
  (define (mod-get-group-instance-blocks igroup-instance igroup-id config)
    (map (cute subnode-ref <> igroup-instance)
  	 (filter (lambda (id)
  		   (not (symbol-contains id "_ORDER")))
  		 (config-get-subnode-type-ids igroup-id config 'block))))

  ;; TODO this is very inefficient
  ;;; Get the value of field FIELD-ID in ROW of BLOCK-INSTANCE.
  (define (mod-get-block-field-value block-instance row field-id mdconf)
    (if (> (- (length block-instance) 2)
	   row)
	(list-ref (list-ref (cddr block-instance)
			    row)
		  (config-get-block-field-index (config-get-parent-node-id
						 field-id (config-itree mdconf))
						field-id mdconf))
	'()))

  ;;; Set the active MD command info string from the given mdconf config-inode
  ;;; FIELD-ID.
  (define (md-command-info field-id mdef)
    (let ((command (config-get-inode-source-command field-id mdef)))
      (string-append
       (symbol->string field-id) ": "
       (if (command-has-flag? command 'is-note)
	   (string-append
	    (normalize-note-name (lowest-note (command-keys command)))
	    " - "
	    (normalize-note-name (highest-note (command-keys command)))
	    " ")
	   "")
       (command-description command))))

  ;;; Returns the values of all field node instances of the given ROW of the
  ;;; given non-order block-instances in the given GROUP-INSTANCE as a
  ;;; flat list.
  ;;; BLOCK-INSTANCE-IDS must be a list containing the requested numerical
  ;;; block instance IDs for each non-order block in the group.
  ;;; Values are returned as strings, except for trigger fields.
  ;;; Empty (unset) instance values will be returned as `#f`.
  (define (mod-get-row-values group-instance block-instance-ids row mdef)
    (flatten
     (map (lambda (block-inst-id block-node)
	    (let ((block-contents (cddr (inode-instance-ref block-inst-id
							    block-node))))
	      (map (lambda (value)
		     ;; TODO should drop this conversion and just return
		     ;; nil
		     (and (not (null? value))
			  value))
		   (if (>= row (length block-contents))
		       (make-list (length (config-get-subnode-ids
					   (car block-node)
					   (config-itree mdef)))
				  '())
		       (list-ref block-contents row)))))
	  block-instance-ids
	  (remove (lambda (node)
		    (symbol-contains (car node) "_ORDER"))
		  (cddr group-instance)))))

  ;;; Returns the values of all field node instances of the non-order block
  ;;; instances in the given `group-instance`, as a list of row value sets.
  ;;; Effectively calls md-mod-get-row-values on each row of the relevant
  ;;; blocks.
  (define (mod-get-block-values group-instance order-pos mdef)
    (map (lambda (pos)
	   (mod-get-row-values group-instance (cdr order-pos) pos mdef))
	 (iota (car order-pos))))

  ;;; Returns the group instance's order node (instance 0)
  (define (mod-get-group-instance-order igroup-instance igroup-id)
    (cadr (subnode-ref (symbol-append igroup-id '_ORDER) igroup-instance)))

  ;; TODO swap argument order
  ;;; Returns the values of all order fields as a list of row value sets.
  ;;; Values are normalized, ie. empty positions are replaced with repeated
  ;;; values from an earlier row.
  (define (mod-get-order-values group-id group-instance)
    (repeat-block-row-values (cddr (mod-get-group-instance-order group-instance
								 group-id))))

  ;; TODO swap argument order
  ;;; Returns the total number of all block rows in the given group node
  ;;; instance. The containing group node must be ordered. The result is equal
  ;;; to the length of the block nodes as if they were combined into a single
  ;;; instance after being mapped onto the order node.
  (define (get-ordered-group-length group-id group-instance)
    (apply + (map car (mod-get-order-values group-id group-instance))))


  ;; ---------------------------------------------------------------------------
  ;;; ### Inode mutators
  ;; ---------------------------------------------------------------------------

  ;; TODO error checks, bounds check/adjustment for block nodes
  ;;; Set one or more INSTANCES of the node with NODE-ID. INSTANCES must
  ;;; be an alist containing the node instance id in car, and the new value in
  ;;; cdr.
  (define (node-set! parent-node-instance node-id instances mod)
    (let* ((mdconf (mdmod-config mod))
	   (parent-id
	    (config-get-parent-node-id node-id (config-itree mdconf)))
	   (parent-node
	    (or ((node-path parent-node-instance)
		 (mdmod-global-node mod))
		(let ((split-path (string-split parent-node-instance "/")))
		  (node-set! (string-intersperse (drop-right split-path 2)
						 "/")
			     parent-id
			     `((,(string->number (car (reverse split-path)))
				#f))
			     mod)
		  ((node-path parent-node-instance)
		   (mdmod-global-node mod))))))
      (if (eqv? 'block (inode-config-type (config-inode-ref parent-id mdconf)))
	  (let ((field-index (config-get-block-field-index parent-id node-id
							   mdconf)))
	    (for-each
	     (lambda (instance)
	       ;; TODO utterly messy work-around because applying
	       ;; list-set! directly trashes the list contents
	       (if (< (length parent-node) (+ 3 (car instance)))
		   (let ((blank-row (make-list (length (config-get-subnode-ids
							parent-id
							(config-itree mdconf)))
					       '())))
		     (set! (cddr parent-node)
		       (append (cddr parent-node)
			       (make-list (- (car instance)
					     (- (length parent-node) 2))
					  blank-row)
			       (list (append
				      (take blank-row
					    field-index)
				      (cons (cadr instance)
					    (drop blank-row
						  (+ 1 field-index))))))))
		   (let ((row (list-copy* (list-ref (cddr parent-node)
						    (car instance)))))
		     (list-set! row field-index (cadr instance))
		     (list-set! parent-node
				(+ 2 (car instance))
			  	row))))
	     instances))
	  (for-each (lambda (instance)
		      (set! (cddr parent-node)
			(alist-update
			 node-id
			 (alist-update (car instance)
				       (cdr instance)
				       (alist-ref node-id (cddr parent-node)))
			 (cddr parent-node))))
		    instances))))

  ;;; Delete the block field instance of FIELD-ID at ROW. Does nothing if ROW
  ;;; does not exist in BLOCK-INSTANCE.
  (define (remove-block-field block-instance field-id row mdconf)
    (when (> (- (length block-instance) 2)
	     row)
      (let* ((columns (transpose (cddr block-instance)))
	     (block-id (config-get-parent-node-id
			field-id (config-itree mdconf)))
	     (field-index (config-get-block-field-index
			   block-id field-id mdconf)))
	(transpose (map (lambda (column index)
			  (if (= index field-index)
			      (append (take column row)
				      (if (> (length column) 1)
				          (append (drop column (+ 1 row)) '(()))
					  '()))
			      column))
			columns (iota (length columns)))))))

  ;;; Insert an instance of the block field FIELD-ID into the block node
  ;;; instance BLOCK-INSTANCE, inserting at ROW and setting VALUE. Returns a
  ;;; fresh block node instance.
  (define (insert-block-field block-instance field-id row value mdconf)
    (let* ((block-id (config-get-parent-node-id field-id (config-itree mdconf)))
	   (columns
	    (transpose
	     (if (> (length block-instance) (+ 2 row))
		 (cddr block-instance)
		 (append (cddr block-instance)
			 (make-list (- row (- (length block-instance) 3))
				    (make-list (length (config-get-subnode-ids
							block-id
							(config-itree mdconf)))
					       '()))))))
	   (field-index
	    (config-get-block-field-index block-id field-id mdconf)))
      (transpose (map (lambda (column index)
			(if (= index field-index)
			    (append (take column row)
				    (list value)
				    (drop column row))
			    (append column '(()))))
		      columns (iota (length columns))))))

  ;;; Delete one or more INSTANCES from the node with NODE-ID.
  (define (node-remove! parent-instance-path node-id instances mod)
    (let* ((mdconf (mdmod-config mod))
	   (parent-id (config-get-parent-node-id node-id (config-itree mdconf)))
	   (parent-instance ((node-path parent-instance-path)
			     (mdmod-global-node mod))))
      (if (eqv? 'block (config-get-parent-node-type node-id mdconf))
	  (for-each (lambda (instance)
		      (when (> (length parent-instance) (+ 2 (car instance)))
			(set! (cddr parent-instance)
			  (remove-block-field parent-instance node-id
					      (car instance) mdconf))))
		    instances)
	  ;; TODO this likely doesn't work.
	  (for-each (cute alist-delete!
		      <> (alist-ref node-id (cddr parent-instance)))
		    instances))))

  ;;; Insert one or more INSTANCES into the node with NODE-ID. INSTANCES
  ;;; must be a list of node-instance-id, value pairs.
  (define (node-insert! parent-instance-path node-id instances mod)
    (let* ((mdconf (mdmod-config mod))
	   (parent-id (config-get-parent-node-id node-id (config-itree mdconf)))
	   (parent-instance ((node-path parent-instance-path)
			     (mdmod-global-node mod))))
      (if (eqv? 'block (config-get-parent-node-type node-id mdconf))
	  (for-each (lambda (instance)
		      (set! (cddr parent-instance)
			(insert-block-field parent-instance node-id
					    (car instance) (cadr instance)
					    mdconf)))
		    instances)
	  ;; TODO this likely does not work
	  (for-each (lambda (instance)
		      (alist-update! (car instance)
				     (cdr instance)
				     (alist-ref node-id
						(cddr parent-instance))))
		    instances))))

  ;;; Insert one or more rows into the block instance at BLOCK-INSTANCE-PATH.
  ;;; Rows shall be a list of lists, where each sublist contains a row number
  ;;; in car, and a list of field values in cdr.
  (define (block-row-insert! parent-instance-path block-id instances mod)
    (letrec* ((mdef (mdmod-config mod))
	      (parent-instance ((node-path parent-instance-path)
				(mdmod-global-node mod)))
	      (block-instances-to-update (map car instances))
	      (empty-row (make-list (length (config-get-subnode-ids
					     block-id
					     (config-itree mdef)))
				    '()))
	      (insert-rows
	       (lambda (orig-rows new-rows row-idx)
		 (print "insert-rows, orig-rows: " orig-rows ", new-rows: " new-rows
			", row-idx: " row-idx)
		 (if (null? new-rows)
		     orig-rows
		     (if (= row-idx (caar new-rows))
			 (cons (cadar new-rows)
			       (insert-rows orig-rows
					    (cdr new-rows)
					    (+ 1 row-idx)))
			 (if (null? orig-rows)
			     (cons empty-row
				   (insert-rows '() new-rows (+ 1 row-idx)))
			     (cons (car orig-rows)
				   (insert-rows (cdr orig-rows)
						new-rows
						(+ 1 row-idx)))))))))
      (for-each
       (lambda (block-instance-spec)
	 (let ((sorted-rows (sort (cdr block-instance-spec)
				  (lambda (x y) (<= (car x) (car y))))))
	   (set! (cddr parent-instance)
	     (alist-update
	      block-id
	      (map (lambda (block-instance)
		     (if (memq (car block-instance) block-instances-to-update)
			 (append (take block-instance 2)
				 (insert-rows (cddr block-instance)
					      sorted-rows
					      0))
			 block-instance))
		   (cdr (subnode-ref block-id parent-instance)))
	      (cddr parent-instance)))))
       instances)
      ;; (for-each
      ;;  (lambda (row)
      ;; 	 (set! (cddr block-instance)
      ;; 	   (let ((contents
      ;; 		  (if (> (length (cddr block-instance))
      ;; 			 (car row))
      ;; 		      (append (cddr block-instance)
      ;; 			      (make-list (- (+ 1 (car row))
      ;; 					    (length (cddr block-instance)))
      ;; 					 empty-row)))))
      ;; 	     (append (take contents (car row))
      ;; 		     (cdr row)
      ;; 		     (drop contents (car row))))))
      ;;  rows)
      ))

  ;;; Remove one or more rows from a block node instance. PARENT-INSTANCE-PATH
  ;;; must be a node path to the parent group node instance. BLOCK-ID must be
  ;;; the ID of the block node, and INSTANCES must be an alist, where the keys
  ;;; are the IDs of the block instances to change, and the values are lists
  ;;; containing a row number in car.
  (define (block-row-remove! parent-instance-path block-id instances mod)
    (let ((parent-instance ((node-path parent-instance-path)
			    (mdmod-global-node mod)))
	  (block-instances-to-update (map car instances)))
      (set! (cddr parent-instance)
	(alist-update
	 block-id
	 (map (lambda (block-instance)
		(if (memq (car block-instance) block-instances-to-update)
		    (append
		     (take block-instance 2)
		     (filter-map
		      (lambda (row idx)
			(and (not (memq idx (map car
						 (alist-ref (car block-instance)
							    instances))))
			     row))
		      (cddr block-instance)
		      (iota (length (cddr block-instance)))))
		    block-instance))
	      (cdr (subnode-ref block-id parent-instance)))
	 (cddr parent-instance)))))


  ;; ---------------------------------------------------------------------------
  ;;; ### Generators
  ;; ---------------------------------------------------------------------------

  ;; TODO respect config constraints on number of instances to generate
  ;;; Generate a new, empty inode instance based on the config MDCONF.
  (define (generate-new-inode-instance mdconf node-id block-length)
    (append '(0 #f)
	    (case (inode-config-type (hash-table-ref (config-inodes mdconf)
						     node-id))
	      ((field) (command-default (config-get-inode-source-command
					 node-id mdconf)))
	      ((block)
	       (if (symbol-contains node-id "_ORDER")
		   (list (cons block-length
			       (make-list
				(sub1 (length (config-get-subnode-ids
					       node-id (config-itree mdconf))))
				0)))
		   (make-list block-length
			      (make-list
			       (length (config-get-subnode-ids
					node-id (config-itree mdconf)))
			       '()))))
	      ((group) (map (lambda (subnode-id)
			      (list subnode-id
				    (generate-new-inode-instance
				     mdconf subnode-id block-length)))
			    (config-get-subnode-ids node-id
						    (config-itree mdconf)))))))

  ;;; Generate a new, empty mdmod based on the config MDCONF. Block instances
  ;;; are generated with length BLOCK-LENGTH by default, unless other
  ;;; constraints apply from the config.
  (define (generate-new-mdmod mdconf block-length)
    (cons mdconf `(GLOBAL ,(generate-new-inode-instance
			    mdconf 'GLOBAL block-length))))

  ;;; Derive a new MDAL module from the module MOD, which contains a single
  ;;; row of block data in the group with GROUP-ID. The row is composed from
  ;;; position ROW in the set of patterns represented by ORDER-POS.
  (define (derive-single-row-mdmod mod group-id order-pos row)
    (letrec*
	((config (mdmod-config mod))
	 (order-id (symbol-append group-id '_ORDER))
	 (make-single-row-group
	  (lambda (node-instance)
	    (let ((block-ids (remove (cute eqv? <> order-id)
				     (config-get-subnode-ids
				      group-id (config-itree config))))
		  (order-pos (list-ref (mod-get-order-values group-id
							     node-instance)
				       order-pos)))
	      (append
	       (take node-instance 2)
	       (map (lambda (subnode)
		      (if (eqv? order-id (car subnode))
			  `(,order-id
			    (0 #f ,(cons 1 (make-list (sub1 (length order-pos))
						      0))))
			  `(,(car subnode)
			    (0 #f
			       ,(let ((rows (repeat-block-row-values
					     (cddr (inode-instance-ref
						    (list-ref
						     order-pos
						     (+ 1 (list-index
							   (cute eqv? <>
								 (car subnode))
							   block-ids)))
						    subnode)))))
				  (if (> (length rows) row)
				      (list-ref rows row)
				      (make-list (length
						  (config-get-subnode-ids
						   (car subnode)
						   (config-itree config)))
						 '())))))))
		    (cddr node-instance))))))
	 (extract-nodes
	  (lambda (root)
	    (cons (car root)
		  (map (lambda (node-instance)
			 (case (inode-config-type (config-inode-ref (car root)
								    config))
			   ((field block) node-instance)
			   ((group) (if (eqv? group-id (car root))
					(make-single-row-group node-instance)
					(append (take node-instance 2)
						(map extract-nodes
						     (cddr node-instance)))))))
		       (cdr root))))))
      (cons config (extract-nodes (mdmod-global-node mod)))))

  ;;; Derive a new MDAL module from the module MOD, with the order list of
  ;;; group GROUP-ID modified to only contain the step ORDER-POS.
  (define (derive-single-pattern-mdmod mod group-id order-pos)
    (letrec*
	((config (mdmod-config mod))
	 (extract-nodes
	  (lambda (root)
	    (cons (car root)
		  (map (lambda (node-instance)
			 (case (inode-config-type (config-inode-ref (car root)
								    config))
			   ((field) node-instance)
			   ((block)
			    (if (eqv? (car root)
				      (symbol-append group-id '_ORDER))
				(append '(0 #f)
					(list (list-ref (repeat-block-row-values
							 (cddr node-instance))
							order-pos)))
				node-instance))
			   ((group)
			    (append (take node-instance 2)
				    (map extract-nodes (cddr node-instance))))))
		       (cdr root))))))
      (cons (mdmod-config mod)
	    (extract-nodes (mdmod-global-node mod)))))

  ) ;; end module mdal
