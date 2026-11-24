;;; om-dash-forge.el --- om-dash: forge-independent helpers for issue trackers -*- lexical-binding: t -*-

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

;; Helpers shared by forge integrations (github, and possibly gitlab,
;; gitea, etc. in the future).
;;
;; Adding a forge, e.g. gitlab, would mean:
;;  - om-dash-gitlab.el: `org-dblock-write:om-dash-gitlab' block, its
;;    settings, fetching, and translation of topics into rows; topics
;;    are alists like `gh pr list --json' output (`url', `state',
;;    `number', `title', `parent', ...) so that nesting, grouping and
;;    table code can be reused;
;;  - om-dash-gitlab-commands.el: gitlab backend of forge commands;
;;    registers itself with `om-dash--forge-register-backend' and
;;    implements every `om-dash-forge--ACTION' generic function of
;;    om-dash-forge-commands.el, 1:1 (unsupported features are reported
;;    with `om-dash--forge-unsupported'); built on
;;    `om-dash--table-row-values', `om-dash--forge-read-list',
;;    `om-dash--forge-diff-args', `om-dash--forge-update-row-cells' and
;;    `om-dash--edit-text';
;;  - key bindings: none, commands and keys are shared (see
;;    om-dash-forge-commands.el);
;;  - “OM_DASH_GITLAB“ drawer parameters work automatically, since
;;    property name is derived from block name.

;;; Code:

(require 'om-dash-core)
(require 'om-dash-table)
(require 'cl-lib)
(require 'seq)
(require 's)

(defun om-dash--forge-nest-topics (topics)
  "Order TOPICS so that sub-issues follow their parent issues.

Returns list of (TOPIC . DEPTH).  A topic is nested under its parent
if the parent is also present in TOPICS; otherwise it's a top-level
row.  Order of TOPICS (i.e. `:sort') is kept among top-level rows and
among children of the same parent.  Nesting can be arbitrarily deep."
  (let ((topics (append topics nil))
        (by-url (make-hash-table :test 'equal))
        (children (make-hash-table :test 'equal))
        roots
        result)
    (dolist (topic topics)
      (puthash (cdr (assoc 'url topic)) topic by-url))
    (dolist (topic topics)
      (let ((parent-url (cdr (assoc 'url (cdr (assoc 'parent topic))))))
        (if (and parent-url
                 (gethash parent-url by-url)
                 (not (equal parent-url (cdr (assoc 'url topic)))))
            (puthash parent-url
                     (append (gethash parent-url children) (list topic))
                     children)
          (push topic roots))))
    (cl-labels ((walk (topic depth)
                  (push (cons topic depth) result)
                  ;; depth limit guards against malformed (cyclic) data
                  (when (< depth 50)
                    (dolist (child (gethash (cdr (assoc 'url topic)) children))
                      (walk child (1+ depth))))))
      (dolist (root (nreverse roots))
        (walk root 0)))
    (nreverse result)))

(defun om-dash--split-list (str separators)
  "Split STR by any of SEPARATORS chars; strip “@“ prefixes and blanks.
“@me“ is kept as is, since gh treats it as the current user."
  (when str
    (seq-remove #'s-blank-p
                (seq-map (lambda (item)
                           (let ((item (s-trim item)))
                             (if (equal item "@me")
                                 item
                               (s-chop-prefix "@" item))))
                         (split-string str (format "[%s]" separators))))))

(defun om-dash--forge-read-list (prompt candidates initial)
  "Read a list of strings with completion over CANDIDATES.
INITIAL is the current list, used as initial input."
  (seq-uniq
   (seq-remove #'s-blank-p
               (seq-map #'s-trim
                        (completing-read-multiple
                         prompt candidates nil nil
                         (when initial
                           (concat (s-join "," initial) ",")))))))

(defun om-dash--forge-diff-args (current desired add-flag remove-flag)
  "Return gh arguments that turn CURRENT list into DESIRED list."
  (append
   (mapcan (lambda (item) (list add-flag item))
           (seq-difference desired current))
   (mapcan (lambda (item) (list remove-flag item))
           (seq-difference current desired))))

(defun om-dash--forge-update-row-cells (marker updates)
  "Update cells of the row at MARKER (see `om-dash--table-update-row')."
  (with-current-buffer (marker-buffer marker)
    (save-excursion
      (goto-char marker)
      (beginning-of-line)
      (when (org-at-table-p)
        (om-dash--table-update-row updates)))))

(provide 'om-dash-forge)
;;; om-dash-forge.el ends here
