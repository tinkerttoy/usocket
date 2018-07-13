;;;; See LICENSE for licensing information.

(in-package :usocket)

(defparameter *backend* :iolib)

(defparameter +iolib-error-map+
 `((iolib/sockets:socket-address-in-use-error        . address-in-use-error) ;
   (iolib/sockets:socket-address-family-not-supported-error . socket-type-not-supported-error)
   (iolib/sockets:socket-address-not-available-error . address-not-available-error)
   (iolib/sockets:socket-network-down-error          . network-down-error)
   (iolib/sockets:socket-network-reset-error         . network-reset-error)
   (iolib/sockets:socket-network-unreachable-error   . network-unreachable-error)
   ;; (iolib/sockets:socket-no-network-error . ?)
   (iolib/sockets:socket-connection-aborted-error    . connection-aborted-error)
   (iolib/sockets:socket-connection-reset-error      . connection-reset-error)
   (iolib/sockets:socket-connection-refused-error    . connection-refused-error)
   (iolib/sockets:socket-connection-timeout-error    . deadline-timeout-error)
   ;; (iolib/sockets:socket-connection-in-progress-error . ?)
   (iolib/sockets:socket-endpoint-shutdown-error     . network-down-error)
   (iolib/sockets:socket-no-buffer-space-error       . no-buffers-error)
   (iolib/sockets:socket-host-down-error             . host-down-error)
   (iolib/sockets:socket-host-unreachable-error      . host-unreachable-error)
   ;; (iolib/sockets:socket-already-connected-error . ?)
   ;; (iolib/sockets:socket-not-connected-error . ?)
   (iolib/sockets:socket-option-not-supported-error  . operation-not-permitted-error)
   (iolib/sockets:socket-operation-not-supported-error . operation-not-supported-error)
   (iolib/sockets:unknown-protocol                   . protocol-not-supported-error)
   ;; (iolib/sockets:unknown-interface . ?)
   (iolib/sockets:unknown-service                    . protocol-not-supported-error)
   ;; (iolib/sockets:socket-error . ,#'map-socket-error) ; no such function

   ;; Nameservice errors (src/sockets/dns/conditions.lisp)
   (iolib/sockets:resolver-error . ns-error)
   (iolib/sockets:resolver-fail-error . ns-no-recovery-error)
   (iolib/sockets:resolver-again-error . ns-try-again-condition)
   (iolib/sockets:resolver-no-name-error . ns-host-not-found-error)
   (iolib/sockets:resolver-unknown-error . ns-unknown-error)
   ))

(defun handle-condition (condition &optional (socket nil))
  "Dispatch correct usocket condition."
  (let* ((usock-error (cdr (assoc (type-of condition) +iolib-error-map+)))
	 (usock-error (if (functionp usock-error)
			  (funcall usock-error condition)
			usock-error)))
    (cond ((typep condition 'iolib/sockets:resolver-error)
	   (error usock-error :host-or-ip (iolib/sockets:resolver-error-datum condition)))
	  (usock-error
	   (error usock-error :socket socket)))))

(defun ipv6-address-p (host)
  nil) ; TODO

(defun socket-connect (host port &key (protocol :stream) (element-type 'character)
                       timeout deadline
                       (nodelay t) ;; nodelay == t is the ACL default
                       local-host local-port)
  (with-mapped-conditions ()
    (let* ((remote (when (and host port) (iolib/sockets:ensure-hostname host)))
	   (local  (when (and local-host local-port)
		     (iolib/sockets:ensure-hostname local-host)))
	   (ipv6-p (or (ipv6-address-p remote)
		       (ipv6-address-p local)))
	   (socket (apply #'iolib/sockets:make-socket
			  `(:type ,protocol
			    :address-family :internet
			    :ipv6 ,ipv6-p
			    :connect ,(cond ((eq protocol :stream) :active)
					    ((and host port)       :active)
					    (t                     :passive))
			    ,@(when local
				`(:local-host ,local :local-port ,local-port))
			    :nodelay nodelay))))
      (when remote
	(apply #'iolib/sockets:connect
	       `(,socket ,remote :port ,port ,@(when timeout `(:wait ,timeout)))))
      (ecase protocol
	(:stream
	 (make-stream-socket :stream socket :socket socket))
	(:datagram
	 (make-datagram-socket socket :connected-p (and remote t)))))))

(defmethod socket-close ((usocket usocket))
  (close (socket usocket)))

(defmethod socket-shutdown ((usocket stream-usocket) direction)
  (with-mapped-conditions ()
    (case direction
      (:input
       (iolib/sockets:shutdown (socket usocket) :read t))
      (:output
       (iolib/sockets:shutdown (socket usocket) :write t))
      (t ; :io by default
       (iolib/sockets:shutdown (socket usocket) :read t :write t)))))

(defun socket-listen (host port
                           &key reuseaddress
                           (reuse-address nil reuse-address-supplied-p)
                           (backlog 5)
                           (element-type 'character))
  (with-mapped-conditions ()
    (make-stream-server-socket
      (iolib/sockets:make-socket :connect :passive
				 :address-family :internet
				 :local-host host
				 :local-port port
				 :backlog backlog
				 :reuse-address (or reuse-address reuseaddress)))))

(defmethod socket-accept ((usocket stream-server-usocket) &key element-type)
  (with-mapped-conditions (usocket)
    (let ((socket (iolib/sockets:accept-connection (socket usocket))))
      (make-stream-socket :socket socket :stream socket))))

(defmethod get-local-address ((usocket usocket))
  (iolib/sockets:local-host (socket usocket)))

(defmethod get-peer-address ((usocket stream-usocket))
  (iolib/sockets:remote-host (socket usocket)))

(defmethod get-local-port ((usocket usocket))
  (iolib/sockets:local-port (socket usocket)))

(defmethod get-peer-port ((usocket stream-usocket))
  (iolib/sockets:remote-port (socket usocket)))

(defmethod get-local-name ((usocket usocket))
  (values (get-local-address usocket)
          (get-local-port usocket)))

(defmethod get-peer-name ((usocket stream-usocket))
  (values (get-peer-address usocket)
          (get-peer-port usocket)))

(defmethod socket-send ((usocket datagram-usocket) buffer size &key host port (offset 0))
  (apply #'iolib/sockets:send-to
	 `(,(socket usocket) ,buffer :start ,offset :end ,(+ offset size)
			     ,@(when (and host port)
				 `(:remote-host ,(iolib/sockets:ensure-hostname host)
				   :remote-port ,port)))))

;; TODO: check the return values structure
(defmethod socket-receive ((usocket datagram-usocket) buffer length &key start end)
  (iolib/sockets:receive-from (socket usocket)
			      :buffer buffer :size length :start start :end end))

;; IOlib uses (SIMPLE-ARRAY (UNSIGNED-BYTE 16) (8)) to represent IPv6 addresses,
;; while USOCKET shared code uses (SIMPLE-ARRAY (UNSIGNED-BYTE 8) (16)). Here we do the
;; conversion.
(defun iolib-vector-to-vector-quad (host)
  (etypecase host
    ((or (vector t 4)  ; IPv4
         (array (unsigned-byte 8) (4)))
     host)
    ((or (vector t 8) ; IPv6
         (array (unsigned-byte 16) (8)))
      (loop with vector = (make-array 16 :element-type '(unsigned-byte 8))
            for i below 16 by 2
            for word = (aref host (/ i 2))
            do (setf (aref vector i) (ldb (byte 8 8) word)
                     (aref vector (1+ i)) (ldb (byte 8 0) word))
            finally (return vector)))))

(defun get-hosts-by-name (name)
  (multiple-value-bind (address more-addresses)
      (iolib/sockets:lookup-hostname name :ipv6 *ipv6*)
    (mapcar #'(lambda (x) (iolib-vector-to-vector-quad
			   (iolib/sockets:address-name x)))
	    (cons address more-addresses))))

(defvar *default-event-base* nil)

(defun %setup-wait-list (wait-list)
  (setf (wait-list-%wait wait-list)
	(or *default-event-base*
	    ;; iolib/multiplex:*default-multiplexer* is used here
	    (make-instance 'iolib/multiplex:event-base))))

(defun make-usocket-read-handler (usocket disconnector)
  (lambda (fd event exception)
    (declare (ignore fd event exception))
    (handler-case
	(if (eq (state usocket) :write)
	    (setf (state usocket) :read-write)
	  (setf (state usocket) :read))
      (end-of-file ()
	(funcall disconnector :close)))))

(defun make-usocket-write-handler (usocket disconnector)
  (lambda (fd event exception)
    (declare (ignore fd event exception))
    (handler-case
	(if (eq (state usocket) :read)
	    (setf (state usocket) :read-write)
	  (setf (state usocket) :write))
      (end-of-file ()
	(funcall disconnector :close))
      (iolib/streams:hangup ()
	(funcall disconnector :close)))))

(defun make-usocket-error-handler (usocket disconnector)
  (lambda (fd event exception)
    (declare (ignore fd event exception))
    (handler-case
	(setf (state usocket) nil)
      (end-of-file ()
	(funcall disconnector :close))
      (iolib/streams:hangup ()
	(funcall disconnector :close)))))

(defun make-usocket-disconnector (event-base usocket)
  (lambda (&rest events)
    (let* ((socket (socket usocket))
	   (fd (iolib/sockets:socket-os-fd socket)))
      (if (not (intersection '(:read :write :error) events))
	  (iolib/multiplex:remove-fd-handlers event-base fd :read t :write t :error t)
	(progn
	  (when (member :read events)
	    (iolib/multiplex:remove-fd-handlers event-base fd :read t))
	  (when (member :write events)
	    (iolib/multiplex:remove-fd-handlers event-base fd :write t))
	  (when (member :error events)
	    (iolib/multiplex:remove-fd-handlers event-base fd :error t))))
      ;; and finally if were asked to close the socket, we do so here
      (when (member :close events)
	(close socket :abort t)))))

(defun %add-waiter (wait-list waiter)
  (let ((event-base (wait-list-%wait wait-list)))
    ;; reset socket state
    (setf (state waiter) nil)
    ;; set I/O handlers
    (iolib/multiplex:set-io-handler
      event-base
      (iolib/sockets:socket-os-fd (socket waiter))
      :read
      (make-usocket-read-handler waiter
				 (make-usocket-disconnector event-base waiter)))
    (iolib/multiplex:set-io-handler
      event-base
      (iolib/sockets:socket-os-fd (socket waiter))
      :write
      (make-usocket-write-handler waiter
				  (make-usocket-disconnector event-base waiter)))
    ;; set error handler
    (iolib/multiplex:set-error-handler
      event-base
      (iolib/sockets:socket-os-fd (socket waiter))
      (make-usocket-error-handler waiter
				  (make-usocket-disconnector event-base waiter)))))

(defun %remove-waiter (wait-list waiter)
  (let ((event-base (wait-list-%wait wait-list)))
    (iolib/multiplex:remove-fd-handlers event-base
					(iolib/sockets:socket-os-fd (socket waiter))
					:read t
					:write t
					:error t)))

;; NOTE: `wait-list-waiters` returns all usockets
(defun wait-for-input-internal (wait-list &key timeout)
  (let ((event-base (wait-list-%wait wait-list)))
    (handler-case
	(iolib/multiplex:event-dispatch event-base
					:timeout timeout)
      (iolib/streams:hangup ())
      (end-of-file ()))
    ;; close the event-base after use
    (unless (eq event-base *default-event-base*)
      (close event-base))))
