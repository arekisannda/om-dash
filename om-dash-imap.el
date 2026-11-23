;;; om-dash-imap.el --- om-dash: IMAP folders block -*- lexical-binding: t -*-

;; Copyright (C) 2024 Victor Gaydov and contributors

;;; License:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; `om-dash-imap' dynamic block: unread mail counters of IMAP folders.

;;; Code:

(require 'om-dash-core)
(require 'om-dash-table)
(require 'auth-source)
(require 'imap)
(require 's)
(require 'seq)

(defcustom om-dash-imap-columns
  '(:state
    :new
    :unread
    :total
    :folder)
  "Column list for `om-dash-imap' tables.

Supported values:

| symbol      | example            |
|-------------+--------------------|
| :state      | NEW, UNREAD, CLEAN |
| :new        | 10                 |
| :unread     | 20                 |
| :total      | 30                 |
| :folder     | foo/bar            |"
  :package-version '(om-dash . "0.3")
  :group 'om-dash
  :type '(repeat symbol))

(defcustom om-dash-imap-default-server
  '( :host nil
     :port nil
     :machine nil
     :user nil
     :password nil
     :stream nil
     :auth nil )
  "Default IMAP connection settings.

Fields from this `plist' are used in `om-dash-imap' if corresponding
parameters are not explicitly specified for the block.

Supported properties:

| parameter | description                 |
|-----------+-----------------------------|
| :host     | IMAP server hostmame        |
| :port     | IMAP server port            |
| :machine  | machine name in ~/.authinfo |
| :user     | IMAP username               |
| :password | IMAP password               |
| :stream   | STREAM for `imap-open'      |
| :auth     | AUTH for `imap-open'        |"
  :package-version '(om-dash . "0.4")
  :group 'om-dash
  :type `(plist :options
                ((:host (string :tag "Hostname Or IP"))
                 (:port (choice (integer :tag "Port Number")
                                (const :tag "Auto" nil)))
                 (:machine (choice (string :tag "Machine Name For ~/.authinfo")
                                   (const :tag "Auto" nil)))
                 (:user (choice (string :tag "User")
                                (const :tag "Auto" nil)))
                 (:password (choice (string :tag "Password")
                                    (const :tag "Auto" nil)))
                 (:stream ,(append '(choice)
                                   (seq-map (lambda (s) `(const ,s)) imap-streams)
                                   '((const :tag "Auto" nil))))
                 (:auth ,(append '(choice)
                                 (seq-map (lambda (s) `(const ,s)) imap-authenticators)
                                 '((const :tag "Auto" nil)))))))


(defcustom om-dash-imap-empty-folders nil
  "Whether to display empty IMAP folders.
If nil, empty folders are excluded from the table."
  :package-version '(om-dash . "0.1")
  :group 'om-dash
  :type 'boolean)

(defvar om-dash-imap-host nil
  "OBSOLETE.  Use `:host' property of `om-dash-imap-default-server'.")

(make-obsolete-variable
 'om-dash-imap-host
 'om-dash-imap-default-server "0.4")

(defvar om-dash-imap-port nil
  "OBSOLETE.  Use `:port' property of `om-dash-imap-default-server'.")

(make-obsolete-variable
 'om-dash-imap-port
 'om-dash-imap-default-server "0.4")

(defvar om-dash-imap-machine nil
  "OBSOLETE.  Use `:machine' property of `om-dash-imap-default-server'.")

(make-obsolete-variable
 'om-dash-imap-machine
 'om-dash-imap-default-server "0.4")

(defvar om-dash-imap-user nil
  "OBSOLETE.  Use `:user' property of `om-dash-imap-default-server'.")

(make-obsolete-variable
 'om-dash-imap-user
 'om-dash-imap-default-server "0.4")

(defvar om-dash-imap-password nil
  "OBSOLETE.  Use `:password' property of `om-dash-imap-default-server'.")

(make-obsolete-variable
 'om-dash-imap-password
 'om-dash-imap-default-server "0.4")

(defvar om-dash-imap-stream nil
  "OBSOLETE.  Use `:stream' property of `om-dash-imap-default-server'.")

(make-obsolete-variable
 'om-dash-imap-stream
 'om-dash-imap-default-server "0.4")

(defvar om-dash-imap-auth nil
  "OBSOLETE.  Use `:auth' property of `om-dash-imap-default-server'.")

(make-obsolete-variable
 'om-dash-imap-auth
 'om-dash-imap-default-server "0.4")

(defun om-dash--imap-folder-stats (host port machine user password stream auth folder)
  "Connect to IMAP server and read stats for a folder tree."
  (let ((parent-folder (if (s-present-p folder)
                           (downcase folder)
                         nil))
        folder-stats)
    (unless (and (s-present-p user)
                 (s-present-p password))
      (om-dash--log (format "reading imap credentials from ~/.authinfo for machine \"%s\""
                            machine))
      (let* ((machine (if (s-present-p machine)
                          machine
                        host))
             (credentials (auth-source-user-and-password machine)))
        (unless credentials
          (error "Om-dash: machine %s not found in ~/.authinfo" machine))
        (unless (s-present-p user)
          (setq user (nth 0 credentials)))
        (unless (s-present-p password)
          (setq password (nth 1 credentials)))))
    (om-dash--log
     (format "connecting to imap server: server \"%s:%s\" user \"%s\" stream \"%s\" auth \"%s\""
             host port user stream auth))
    (with-current-buffer (or (imap-open host port stream auth)
                             (error "Om-dash: imap connection failed"))
      (imap-authenticate user password)
      (dolist (folder (imap-mailbox-list (s-concat parent-folder "*")))
        (when (or (not parent-folder)
                  (s-equals-p parent-folder folder)
                  (s-starts-with-p (s-concat parent-folder "/") folder))
          (om-dash--log (format "inspecting imap folder %s"
                                folder))
          (imap-mailbox-select folder)
          (let* ((total-count (length (imap-search "ALL")))
                 (new-count (length (imap-search "NEW")))
                 (unread-count (length (imap-search "UNSEEN")))
                 (state (cond ((> new-count 0) "NEW")
                              ((> unread-count 0) "UNREAD")
                              (t "CLEAN"))))
            (push (list :folder folder
                        :state state
                        :total total-count
                        :new new-count
                        :unread unread-count)
                  folder-stats)))))
    (sort folder-stats
          (lambda (a b)
            (s-less-p (plist-get a :folder)
                      (plist-get b :folder))))))

(defun om-dash--imap-server-prop (params key)
  "Get property from :server or om-dash-imap-default-server."
  (or
   ;; block parameter
   (plist-get (plist-get params :server) key)
   ;; block parameter - old name
   (when-let* ((value (plist-get params key)))
     (warn "om-dash: %S is deprecated, use :server instead." key)
     value)
   ;; variable
   (plist-get om-dash-imap-default-server key)
   ;; variable - old name
   (when-let* ((name (s-concat "om-dash-imap-" (substring (symbol-name key) 1)))
               (value (symbol-value (intern name))))
     (warn "om-dash: %s is deprecated, use om-dash-imap-default-server instead."
           name)
     value)))

;;;###autoload
(defun org-dblock-write:om-dash-imap (params)
  "Builds org heading with a table of IMAP folder(s) and their unread mail counters.

Usage example:
  #+BEGIN: om-dash-imap :folder “foo/bar“
  ...
  #+END:

Custom config:
  #+BEGIN: om-dash-imap :folder “foo/bar“ :server (:host “example.com“ :user “john“ :password “secret“)
  ...
  #+END:

| parameter      | default                       | description                       |
|----------------+-------------------------------+-----------------------------------|
| :server        | `om-dash-imap-default-server' | server connection config          |
| :columns       | `om-dash-imap-columns'        | list of columns to display        |
| :keyword       | auto                          | keyword of OM_DASH_HEADING        |
| :headline      | auto                          | caption of multi-table blocks     |
| :heading-level | auto                          | unused                            |

`:server' defines IMAP connection parameters.  It must be a `plist' which can have
the following properties:

| property  | default                            | description                 |
|-----------+------------------------------------+-----------------------------|
| :host     | required                           | IMAP server hostmame        |
| :port     | auto                               | IMAP server port            |
| :machine  | same as `:host'                    | machine name in ~/.authinfo |
| :user     | match in ~/.authinfo by `:machine' | IMAP username               |
| :password | match in ~/.authinfo by `:machine' | IMAP password               |
| :stream   | auto                               | STREAM arg for `imap-open'  |
| :auth     | auto                               | AUTH arg for `imap-open'    |

If you omit `:server', or some of the properties, their values are substituted with
the corresponding fields from `om-dash-imap-default-server', when present.

`:host' and `:port' define IMAP server address.
Host must be always set, either via `:server' or `om-dash-imap-default-server'.
Port is optional, default value depends on `:auth' method.

`:user' and `:password' define IMAP credentials.
If not set, `om-dash-imap' will find them in ~/.authinfo by matching by `:machine'
property.  If `:machine' isn't set, `:host' value is used for matching.

`:stream' and `:auth' may be used to force `imap-open' to use specific
connection and authentification types.  For example, you can use `network'
and `login' values to force plain-text unencrypted password."
  ;; expand template
  (setq params
        (om-dash--prepare-params params))
  ;; parse params
  (let* ((host (or (om-dash--imap-server-prop params :host)
                   (user-error
                    "Om-dash: missing :host in :server or om-dash-imap-default-server")))
         (port (om-dash--imap-server-prop params :port))
         (machine (om-dash--imap-server-prop params :machine))
         (user (om-dash--imap-server-prop params :user))
         (password (om-dash--imap-server-prop params :password))
         (stream (om-dash--imap-server-prop params :stream))
         (auth (om-dash--imap-server-prop params :auth))
         (folder (or (plist-get params :folder)
                     (user-error "Om-dash: missing :folder")))
         (table-columns (or (om-dash--plist-obsolete params :columns :table-columns)
                            om-dash-imap-columns))
         (keyword (plist-get params :keyword))
         (headline (or (plist-get params :headline)
                       (format "emails (%s)" folder)))
         (heading-level (or (plist-get params :heading-level)
                            (om-dash--choose-level))))
    ;; get stats and format table
    (let* ((column-names
            (seq-map (lambda (col)
                       (pcase col
                         (:state "state")
                         (:new "new")
                         (:unread "unread")
                         (:total "total")
                         (:folder "folder")
                         (_ (user-error "Om-dash: unknown table column %S" col))))
                     table-columns))
           (entries
            (om-dash--imap-folder-stats host port machine user password stream auth folder))
           (todo-p
            (< 0 (seq-count (lambda (entry)
                              (not (string= (plist-get entry :state)
                                            "CLEAN")))
                            entries)))
           table)
      (dolist (entry entries)
        (let* ((state (plist-get entry :state))
               (new (plist-get entry :new))
               (unread (plist-get entry :unread))
               (total (plist-get entry :total))
               (folder (plist-get entry :folder)))
          (when (or om-dash-imap-empty-folders
                    (> total 0))
            (push
             (seq-map (lambda (col)
                        (pcase col
                          (:state (make-om-dash--cell :text state))
                          (:new (make-om-dash--cell :text (number-to-string new)))
                          (:unread (make-om-dash--cell :text (number-to-string unread)))
                          (:total (make-om-dash--cell :text (number-to-string total)))
                          (:folder (make-om-dash--cell :text folder))
                          (_ (user-error "Om-dash: unknown table column %S" col))))
                      table-columns)
             table))))
      (om-dash--insert-heading (or keyword
                                   (om-dash--choose-keyword todo-p))
                               headline
                               heading-level)
      (when table
        (om-dash--insert-table column-names (nreverse table) heading-level))
      (om-dash--remove-empty-line))))

(provide 'om-dash-imap)
;;; om-dash-imap.el ends here
