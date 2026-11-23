;;; om-dash-command.el --- om-dash: shell command and elisp function blocks -*- lexical-binding: t -*-

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

;; `om-dash-command' and `om-dash-function' dynamic blocks: tables
;; from JSON or CSV output of a shell command, or from an elisp function.

;;; Code:

(require 'om-dash-core)
(require 'om-dash-table)
(require 'json)
(require 's)
(require 'seq)

;; https://github.com/mrc/el-csv
(require 'parse-csv nil 'noerror)
(declare-function parse-csv-string-rows "parse-csv")

(defun om-dash--parse-json (columns raw-output)
  "Parse json output to table."
  (let ((parsed-output (json-read-from-string raw-output))
        table)
    (seq-do (lambda (json)
              (let ((col-num 0)
                    row)
                (dolist (col columns)
                  (let* ((field (format "%s"
                                        (cdr (assoc (intern col) json)))))
                    (push (make-om-dash--cell :text field)
                          row))
                  (setq col-num (1+ col-num)))
                (push (nreverse row)
                      table)))
            parsed-output)
    (nreverse table)))

(defun om-dash--parse-csv (columns raw-output)
  "Parse csv output to table."
  (unless (featurep 'parse-csv)
    (error "Om-dash: parse-csv package not found"))
  (let ((parsed-output (parse-csv-string-rows raw-output ?\, ?\" "\n"))
        table)
    (dolist (parsed-row parsed-output)
      (when (seq-some 's-present-p parsed-row)
        (let ((col-num 0)
              row)
          (dolist (_col columns)
            (let ((field (if (< col-num (length parsed-row))
                             (elt parsed-row col-num)
                           "")))
              (push (make-om-dash--cell :text field)
                    row))
            (setq col-num (1+ col-num)))
          (push (nreverse row)
                table))))
    (nreverse table)))

(defun om-dash--parse-link (link)
  "Parse org link."
  (if (string-match org-link-bracket-re (s-trim link))
      (cons (match-string 1 link) (match-string 2 link))
    nil))

;;;###autoload
(defun org-dblock-write:om-dash-command (params)
  "Builds org heading with a table from output of a shell command.

Usage example:
  #+BEGIN: om-dash-command :command “curl -s https://api.github.com/users/octocat/repos“ :format json :columns (“name“ “forks_count“)
  ...
  #+END:

| parameter      | default  | description                             |
|----------------+----------+-----------------------------------------|
| :command       | required | shell command to run                    |
| :columns       | required | column names (list of strings)          |
| :format        | `json'   | command output format (`json' or `csv') |
| :keyword       | auto     | keyword of OM_DASH_HEADING              |
| :headline      | auto     | caption of multi-table blocks           |
| :heading-level | auto     | unused                                  |

If `:format' is `json', command output should be a JSON array of
JSON objects, which have a value for every key from `:columns'.

If `:format' is `csv', command output should be CSV.  First column
of CSV becomes value of first column from `:columns', and so on.

Note: using CSV format requires installing `parse-csv' package
from https://github.com/mrc/el-csv"
  ;; expand template
  (setq params
        (om-dash--prepare-params params))
  ;; parse params
  (let* ((command (or (plist-get params :command)
                      (user-error "Om-dash: missing :command")))
         (format (or (plist-get params :format) 'json))
         (columns (or (plist-get params :columns)
                      (user-error "Om-dash: missing :columns")))
         (keyword (plist-get params :keyword))
         (headline (or (plist-get params :headline)
                       (file-name-nondirectory
                        (car (split-string-shell-command command)))))
         (heading-level (or (plist-get params :heading-level)
                            (om-dash--choose-level))))
    ;; run command
    (let* ((raw-output (om-dash--shell-run command t))
           (table (pcase format
                    (`json (om-dash--parse-json columns raw-output))
                    (`csv (om-dash--parse-csv columns raw-output))
                    (_ (user-error "Om-dash: bad :format %S" format))))
           (is-todo (om-dash--table-todo-p table)))
      (om-dash--insert-heading (or keyword
                                   (om-dash--choose-keyword is-todo))
                               headline heading-level)
      (when table
        (om-dash--insert-table columns table heading-level))
      (om-dash--remove-empty-line))))

;;;###autoload
(defun org-dblock-write:om-dash-function (params)
  "Builds org heading with a table from output of a elisp function.

Usage example:
  #+BEGIN: om-dash-function :func example-func
  ...
  #+END:

| parameter      | default  | description                       |
|----------------+----------+-----------------------------------|
| :func          | required | elisp function to call            |
| :args          | nil      | optional function arguments       |
| :columns       | nil      | list of columns to display        |
| :keyword       | nil      | keyword of OM_DASH_HEADING        |
| :headline      | nil      | caption of multi-table blocks     |
| :heading-level | nil      | unused                            |

The function should return a list of tables, where each table is
a `plist' with the following properties:

| property       | default  | description                                          |
|----------------+----------+------------------------------------------------------|
| :columns       | required | list of column names (strings)                       |
| :data          | required | list of rows, where row is a list of cells (strings) |
| :keyword       | “TODO“   | keyword of OM_DASH_HEADING                           |
| :headline      | auto     | caption of multi-table blocks                        |
| :heading-level | auto     | unused                                               |

Every property returned from function, except `:data', may be overwritten by a block
parameter with the same name, if it is provided.

Example function that returns a single 2x2 table:

  (defun example-func ()
    ;; list of tables
    (list
     ;; table plist
     (list :columns `(“foo“ “bar“)
           :data `((“a“ “b“)
                   (“c“ “d“))
           :keyword “TODO“
           :headline “example table“)))"
  ;; expand template
  (setq params
        (om-dash--prepare-params params))
  ;; parse params
  (let* ((function (or (plist-get params :func)
                       (user-error "Om-dash: missing :func")))
         (args (plist-get params :args))
         (forced-columns (plist-get params :columns))
         (default-keyword (om-dash--choose-keyword nil))
         (forced-keyword (plist-get params :keyword))
         (forced-headline (plist-get params :headline))
         (forced-level (plist-get params :heading-level)))
    ;; run function and build table
    (let* ((tables (apply function args))
           (multiple (> (length tables) 1)))
      (dolist (table-plist tables)
        (let* ((column-names (or forced-columns
                                 (om-dash--plist-obsolete table-plist :columns :column-names)
                                 (user-error "Om-dash: missing :columns")))
               (rows (or (om-dash--plist-obsolete table-plist :data :rows)
                         (user-error "Om-dash: missing :data")))
               (keyword (or forced-keyword
                            (plist-get table-plist :keyword)
                            default-keyword))
               (headline (or forced-headline
                             (plist-get table-plist :headline)
                             (symbol-name function)))
               (heading-level (or forced-level
                                  (om-dash--plist-obsolete table-plist :heading-level :level)
                                  (om-dash--choose-level)))
               table)
          (dolist (row rows)
            (push
             (seq-map (lambda (cell-text)
                        (if-let* ((link (om-dash--parse-link cell-text)))
                            (make-om-dash--cell :text (car link) :link (cdr link))
                          (make-om-dash--cell :text cell-text)))
                      row)
             table))
          (om-dash--insert-heading keyword
                                   headline
                                   heading-level)
          (when multiple
            (om-dash--insert-caption keyword headline))
          (when table
            (om-dash--insert-table column-names (nreverse table) heading-level))))
      (om-dash--remove-empty-line))))

(provide 'om-dash-command)
;;; om-dash-command.el ends here
