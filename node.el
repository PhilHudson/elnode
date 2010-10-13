;;; A simple emacs async http server
;;; this is like node.js, but for elisp (obviously)
;;; (C) Nic Ferrier, 2010

(defvar elnode-server-socket nil
  "Where we store the server socket

This code has been written to allow multiple servers each with
their own request handler. To facilitate that this variable must
be replaced; a hashtable or alist of port->server-process would
be good enough.
")

(defun elnode-sentinel (process status)
  "Sentinel function for the main server and for the client sockets"
  (cond
   ;; Server status
   ((and 
     (equal process elnode-server-socket)
     (equal status "deleted\n"))
    (kill-buffer (process-buffer process))
    (message "elnode server stopped"))

   ;; Client socket status
   ((equal status "connection broken by remote peer\n")
    (if (process-buffer process)
        (kill-buffer (process-buffer process)))
    ;;(message "elnode connection dropped")
    )

   ((equal status "open\n") ;; this says "open from ..."
    (message "elnode opened new connection"))

   ;; Default
   (t
    (message "wtf? %s %s" process status))
   ))


(defun elnode-filter (process data)
  "Filter for the clients.

This does the work of finding and calling the user http
connection handler for a request.

A buffer for the http connection is created, uniquified by the
port number of the connection."
  (let ((buf (or 
              (process-buffer process)
              ;; Set the process buffer (because the server doesn't automatically allocate them)
              ;; the name of the buffer has the client port in it
              ;; the space in the name ensures that emacs does not list it
              (let* ((proc-name (process-name process))
                     (port-match 
                      (string-match "\\*elnode-webserver-proc\\* <127.0.0.1:\\([0-9]+\\)>" proc-name)))
                (set-process-buffer 
                 process 
                 (get-buffer-create (concat " *elnode-request-" (match-string 1 proc-name) "*")))
                (process-buffer process)))))
    (with-current-buffer buf
      (insert data)
      ;; We need to check the buffer for \r\n\r\n which marks the end of HTTP header
      (save-excursion 
        (goto-char (point-min))
        (if (re-search-forward "\r\n\r\n" nil 't)
            (let ((server (process-get process :server)))
              (funcall (process-get server :elnode-http-handler) process)
              )
          )
        )
      )))

(defun elnode-log-fn (server con msg)
  "Log function for elnode.

Serves only to connect the server process to the client processes"
  (process-put con :server server)
  )

(defun elnode-start (request-handler)
  "Start the elnode server.

Most of the work done by the server is actually done by
functions, the sentinel function, the log function and a filter
function.

request-handler is a function which is called with the
request. The function is called with one argument, the
http-connection.

You can use functions such as elnode-http-start and
elnode-http-send-body to send the http response.

Example:

 (defun nic-server (httpcon)
   (elnode-http-start 200 '((\"Content-Type\": \"text/html\")))
   (elnode-http-return \"<html><b>BIG!</b></html>\")
   )
 (elnode-start 'nic-server)
 ;; End
"
  (interactive "aHandler function: ")
  (if (not elnode-server-socket)
      ;; Make a logging func to set the connection's plist to link back to the server
      ;; This let's us bind user handler procs to the server.
      (setq elnode-server-socket 
            (let ((buf (get-buffer-create "*elnode-webserver*")))
              (make-network-process 
               :name "*elnode-webserver-proc*"
               :buffer buf
               :server t
               :nowait 't
               :host 'local
               :service 8023
               :family 'ipv4
               :filter 'elnode-filter
               :sentinel 'elnode-sentinel
               :log 'elnode-log-fn
               :plist `(:elnode-http-handler ,request-handler)
               )
              )))
  )

(defun elnode-stop ()
  "Stop the elnode server"
  (interactive)
  (delete-process elnode-server-socket)
  (setq elnode-server-socket nil)
  )

(defun elnode-http-parse (httpcon)
  "Parse the HTTP header for the process."
  (with-current-buffer (process-buffer httpcon)
    ;; We need to record the end of header so we can use that instead of point-max
    (let* ((lines (split-string (buffer-substring (point-min) (point-max)) "\r\n" 't))
           (status (car lines))
           (header (cdr lines)))
      (process-put httpcon :elnode-http-status status)
      (process-put 
       httpcon 
       :elnode-http-header
       (mapcar 
        (lambda (hdrline)
          (if (string-match "\\([A-Za-z0-9_-]+\\): \\(.*\\)" hdrline)
              (cons (match-string 1 hdrline) (match-string 2 hdrline))))
        header))))
  (process-get httpcon :elnode-http-header)
  )

(defun elnode-http-header (httpcon name)
  "Get the header specified by name from the header"
  (let ((hdr (or 
              (process-get httpcon :elnode-http-header)
              (elnode-http-parse httpcon))))
    (cdr (assoc name hdr))
    ))

(defun elnode-http-parse-status (httpcon &optional property)
  "Parse the status line.

property if specified is the property to return"
  (let ((http-line (process-get httpcon :elnode-http-status)))
    (string-match 
     "\\(GET\\|POST\\|HEAD\\) \\(.*\\) HTTP/\\(1.[01]\\)" 
     http-line)
    (process-put httpcon :elnode-http-method (match-string 1 http-line))
    (process-put httpcon :elnode-http-pathinfo (match-string 2 http-line))
    (process-put httpcon :elnode-http-version (match-string 3 http-line))
    (if property
        (process-get httpcon property))
    )
  )

(defun elnode-http-pathinfo (httpcon)
  "Get the PATHINFO of the request"
  (or
   (process-get httpcon :elnode-http-pathinfo)
   (elnode-http-parse-status httpcon :elnode-http-pathinfo)))

(defun elnode-http-method (httpcon)
  "Get the PATHINFO of the request"
  (or
   (process-get httpcon :elnode-http-method)
   (elnode-http-parse-status httpcon :elnode-http-method)))

(defun elnode-http-version (httpcon)
  "Get the PATHINFO of the request"
  (or
   (process-get httpcon :elnode-http-version)
   (elnode-http-parse-status httpcon :elnode-http-version)))


(defun elnode-http-start (httpcon status &rest header)
  "Start the http response on the specified http connection.

httpcon is the HTTP connection being handled.
status is the HTTP status, eg: 200 or 404
header is a sequence of (header-name . value) pairs.

For example:

 (elnode-http-start httpcon \"200\" '(\"Content-type\" . \"text/html\"))
"
  (let ((http-codes-strings '(("200" . "Ok")
                              (200 . "Ok")
                              ("400" . "Bad Request")
                              (400 . "Bad Request")
                              ("401" . "Authenticate")
                              (401 . "Authenticate")
                              ("404" . "Not Found")
                              (404 . "Not Found")
                              ("500" . "Server Error")
                              (500 . "Server Error")
                              )))
    (process-send-string 
     httpcon 
     (format
      "HTTP/1.1 %s %s\r\n%s\r\n\r\n" 
      status 
      ;; The status text
      (cdr (assoc status http-codes-strings))
      ;; The header
      (or 
       (mapconcat 
        (lambda (p)
          (format "%s: %s" (car p) (cdr p)))
        header
        "\r\n")
       "\r\n")
      ))))

(defun elnode-http-return (httpcon data)
  "End the http response on the specified http connection

httpcon is the http connection.
data must be a string right now."
  (process-send-string httpcon data)
  (delete-process httpcon)
  )


;; A concept for a macro to help with multiple dispatch:
;;
;; (elnode-start 
;;  (elnode-map 
;;   '(("$" 
;;      (elnode-http-start httpcon 200 '(Content-type . "text/html"))
;;      (elnode-http-return httpcon "done"))
;;     ("~\\([A-Za-z0-9_-]\\)"
;;      (elnode-send httpcon (htmlize-directory-list (string-match 1 elnode-url)))))))
;;
;; There are two things defined here:
;; elnode-map is a macro which takes forms like:
;;  (url-regex-pattern body-forms)
;; where url-regex-pattern is an elisp regex that will match the incomming PATHINFO
;; and body-forms is a list of things to do when that happens.
;;
;; elnode-send is a function which send HTML to the http con, doing
;; all the start and return stuff for you (and working out size of the
;; request)
(defun nicferrier-handler (httpcon)
  "Demonstration function"
  (let* ((host (elnode-http-header httpcon "Host"))
         (pathinfo (elnode-http-pathinfo httpcon))
         (body (format 
                "<html><body><b>HELLO @ %s %s %s</b></body></html>" 
                host 
                pathinfo 
                (elnode-http-version httpcon)
                )))
    (elnode-http-start 
     httpcon 
     200
     '("Content-type" . "text/html")
     `("Content-length" . ,(length body))
     )
    (elnode-http-return httpcon body)
    )
  )

;; End
