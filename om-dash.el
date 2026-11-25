;;; om-dash.el --- Building blocks for org-based dashboards -*- lexical-binding: t -*-

;; Copyright (C) 2024 Victor Gaydov and contributors

;; Author: Victor Gaydov <victor@enise.org>
;; Created: 22 May 2024
;; URL: https://github.com/gavv/om-dash
;; Version: 0.7
;; Package-Requires: ((emacs "28.2") (org-ql "0.8.10") (s "1.13.0") (ts "0.3"))
;; Keywords: org, outlines

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

;; `om-dash' implements a set of dynamic blocks for org-mode that you can use
;; to compose a custom dashboard for your projects.

;; The following dynamic blocks are available:
;; * `om-dash-github'
;;   generates a table with issues or pull requests from github repository
;; * `om-dash-orgfile'
;;   generates tables with top-level entries from an org file
;; * `om-dash-imap'
;;   generates table with unread email counters for IMAP folder
;; * `om-dash-command'
;;   generates a table from JSON or CSV output of a shell command
;; * `om-dash-function'
;;   generates a table from output of a Elisp function

;; The package also provides a minor mode `om-dash-mode' that applies
;; highlighting to the generated tables.

;; Forge commands work on the item (issue, pull request, draft) on the
;; current row of a forge block table (e.g. `om-dash-github'); the
;; backend is chosen by the name of the enclosing block.
;; Command `om-dash-forge-set-field' changes the field of the item at
;; point shown in the column at point (for github: state, title,
;; status, tags, assignee, reviewer, milestone, parent); other columns
;; can't be changed.  Command `om-dash-forge-set-parent' sets the
;; parent issue also when the table doesn't show parents.
;; Commands `om-dash-forge-create-item' and `om-dash-forge-create-draft'
;; create an item from a new row typed into the table, and
;; `om-dash-forge-convert-draft' converts a draft to an item.
;; Command `om-dash-forge-edit-body' edits its body in a buffer.
;; Command `om-dash-forge-delete-item' removes it from the project, or
;; with prefix argument deletes it permanently.

;; Command `om-dash-help' shows a reference of all block parameters,
;; properties and keys.

;; Block parameters can be given inline on the “#+BEGIN:“ line, or in
;; property drawers of enclosing headings, which allows to share common
;; configuration between blocks:
;;
;;   * Infra dashboard
;;   :PROPERTIES:
;;   :OM_DASH_GITHUB:  :owner "octocat" :project 7 :group-by :repo
;;   :END:
;;   ** TODO Pull requests
;;   :PROPERTIES:
;;   :OM_DASH_HEADING: t
;;   :END:
;;   #+BEGIN: om-dash-github :type pullreq
;;   #+END:
;;   ** TODO Issues
;;   :PROPERTIES:
;;   :OM_DASH_HEADING: t
;;   :END:
;;   #+BEGIN: om-dash-github :type issue :closed "-1w"
;;   #+END:
;;
;; To make a block update todo keyword of its heading (e.g. TODO if there
;; are open topics, DONE otherwise), set “:OM_DASH_HEADING: t“ property
;; on that heading.  Om-dash never inserts or renames headings.
;;
;; Colors of project statuses in `om-dash-mode' are declared with
;; “OM_DASH_STATUS_FACES“ property (inherited, can be set file-wide with
;; “#+PROPERTY:“), e.g.:
;;
;;   #+PROPERTY: OM_DASH_STATUS_FACES "Todo" "gray60" "In Progress" warning "Done" success
;;
;; “OM_DASH“ applies to all blocks, “OM_DASH_<TYPE>“ (e.g. “OM_DASH_GITHUB“,
;; “OM_DASH_ORGFILE“, “OM_DASH_IMAP“) applies to blocks of that type.
;; Values from nearer headings override outer ones, and inline parameters
;; override all of them.  Long values can be split using “OM_DASH_GITHUB+“.

;; In addition, there is support for templates, which allow to create
;; reusable parameterized configurations of the above blocks.

;; Refer to README.org for examples and screenshots.

;;; Quoting:

;; A brief note on docstring quoting styles in this package:

;;  1. Symbols, functions, and variables are quoted in standard way `like-this'.

;;  2. Since double quotes are used very often in docstrings, we use unicode
;;     quotes “like this“ instead double quotes "like this" to avoid backslash hell.

;;  3. In tables inside docstrings, we use apostrophes 'like-this' instead of
;;     standard quotes `like-this' to prevent quote translation; otherwise, table
;;     alignment would be broken in the help buffer.

;;; Files:

;; om-dash.el is split into modules:
;;   om-dash-core.el              core settings, faces, utilities, block parameters
;;   om-dash-table.el             org table generation and editing
;;   om-dash-edit.el              buffer for editing text (C-c C-c / C-c C-k)
;;   om-dash-forge.el             forge-independent helpers for issue trackers
;;   om-dash-forge-commands.el    forge commands, contract for forge backends
;;   om-dash-github.el            github issues and pull requests block
;;   om-dash-github-commands.el   github backend of forge commands
;;   om-dash-orgfile.el           org file block
;;   om-dash-imap.el              IMAP folders block
;;   om-dash-command.el           shell command and elisp function blocks
;;   om-dash-mode.el              minor mode with highlighting and key bindings
;;   om-dash-help.el              help buffer: reference of settings and keys

;;; Code:

(require 'om-dash-core)
(require 'om-dash-table)
(require 'om-dash-edit)
(require 'om-dash-forge)
(require 'om-dash-forge-commands)
(require 'om-dash-github)
(require 'om-dash-github-commands)
(require 'om-dash-orgfile)
(require 'om-dash-imap)
(require 'om-dash-command)
(require 'om-dash-mode)
(require 'om-dash-help)

;; Make byte compiler happy.
(declare-function org-ql--normalize-query "org-ql" t t)

(provide 'om-dash)
;;; om-dash.el ends here
