;;; om-dash-help.el --- om-dash: help buffer with reference of settings and keys -*- lexical-binding: t -*-

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

;; `om-dash-help' shows a reference of all settings written in org files
;; (block parameters, drawer properties, heading markers) and of key
;; bindings, in a `help-mode' buffer: `symbol' references are links, and
;; keys are generated from `om-dash-command-map'.

;;; Code:

(require 'om-dash-mode)
(require 'help-mode)
(require 'seq)

(defconst om-dash--help-text
  "Om-dash reference: settings written in org files.

Look-and-feel settings (faces, prefixes, widths) are variables instead,
see `customize-group' “om-dash“.  Full documentation of each block is in
its function, e.g. `org-dblock-write:om-dash-github'.

WHERE SETTINGS GO

Inline, on the “#+BEGIN:“ line:

  #+BEGIN: om-dash-github :repo “owner/repo“ :type issue :open “*“
  #+END:

Or in property drawers of the block's heading or any of its ancestors:

  OM_DASH         Parameters of all om-dash blocks.
  OM_DASH_<TYPE>  Parameters of one block type, e.g. OM_DASH_GITHUB.

  * Infra
  :PROPERTIES:
  :OM_DASH_GITHUB:  :owner “octocat“ :project 7
  :OM_DASH_GITHUB+: :group-by :repo
  :END:

Inline parameters win over drawers, nearer headings over outer ones, and
OM_DASH_<TYPE> over OM_DASH on the same heading.  “PROP+“ lines continue
a property.  A blank line inside a property drawer makes org ignore the
whole drawer.

BLOCKS

  om-dash-github    GitHub issues, pull requests, v2 project items,
                    see `org-dblock-write:om-dash-github'.
  om-dash-orgfile   Entries of another org file,
                    see `org-dblock-write:om-dash-orgfile'.
  om-dash-imap      IMAP folders and unread counters,
                    see `org-dblock-write:om-dash-imap'.
  om-dash-command   JSON or CSV output of a shell command,
                    see `org-dblock-write:om-dash-command'.
  om-dash-function  Tables returned by an elisp function,
                    see `org-dblock-write:om-dash-function'.

PARAMETERS OF ALL BLOCKS

  :columns        List of columns to display.
                  Default: per block, e.g. `om-dash-github-columns'.
  :keyword        Keyword of OM_DASH_HEADING heading.
                  Default: auto.
  :headline       Caption of multi-table blocks.
                  Default: auto.
  :heading-level  Unused.
  :template       Template of `om-dash-templates' to expand.
  :column-cookies Org column cookies, e.g. (:title “<30>“ :tags “<r>“):
                  a row of them is added after the header, so that org can
                  shrink or align columns (“#+STARTUP: shrink“ when the
                  file is opened, `org-table-toggle-column-width' after a
                  refresh).  Keys are columns of :columns (names for
                  om-dash-command and om-dash-function).

OM-DASH-GITHUB PARAMETERS

  :repo                  “owner/repo“.
                         Required unless project mode.
  :owner                 User, org or “@me“ owning the project.
                         Default: owner part of :repo.
  :project               V2 project number; without :repo: project mode.
  :owner-type            `user' or `org' (skips detection).
  :project-type          `v2' or `classic'.
                         Default: `v2'.
  :project-status-field  Single-select field used as status.
                         Default: `om-dash-github-project-status-field'.
  :type                  `issue', `pullreq' or `any'.
                         Required.
  :any                   Query for items in any state.
  :open                  Query for open items.
                         Default: “*“ if no query is given.
  :closed                Query for closed items.
  :sort                  Field to sort by, “-field“ = descending.
                         Default: “createdAt“.
  :group-by              Column to group rows by, e.g. :repo.
  :group-order           `asc' / `desc' (natural order), `sort' (first appearance), or a
                         list like (“Todo“ “In Progress“ “Done“) that
                         wins over natural order.
                         Default: `asc'.
  :sub-issues            `nest' under parent or `flat' (project mode).
                         Default: `nest'.
  :title-template        Parts of title cell (see below).
  :done-statuses         Statuses counted as done in heading progress.
                         Default: (“Done“).
  :fields                Json fields of gh queries (repo mode).
                         Default: `om-dash-github-fields'.
  :limit                 Max results per state and type.
                         Default: `om-dash-github-limit'.

OM-DASH-GITHUB QUERIES (:any, :open, :closed)

  (:milestone “1.2.3“ :no-author “bob“)    Simple query (plist).
  “milestone:1.2.3“, “*“, “-1w“            GitHub search string.
  (“label:bug“ “.author.login != ...“)     Search string and jq selector.

Relative times: “-10d“, “-10w“, “-10mo“, “-10y“.  Project mode translates
search strings to jq: “*“, “-1w“, free text (title), state: is: type: no:
milestone: label: author: assignee: repo: created: updated: closed:
merged: (negated with “-“).

Simple query properties (string or list of strings; “*“ = any, “-“ =
none; properties are ANDed, list values ORed):

  :milestone :no-milestone
  :label :every-label :no-label
  :author :no-author
  :assignee :no-assignee
  :reviewer :no-reviewer
  :review-status :no-review-status   `undecided', `required', `requested',
                                     `commented', `approved', `rejected'
  :project :project-type
  :project-status :no-project-status
  :created-at :updated-at :closed-at :merged-at
                                     “2024-02-20“, “-3mo“, (>= “-3mo“),
                                     (range “A“ “B“)

OM-DASH-GITHUB COLUMNS (header in parentheses)

  :state (state)            OPEN, CLOSED, MERGED, DRAFT
  :number (no.)             #123
  :repo (repo)              owner/repo
  :parent (parent)          #12
  :sub-issues (sub-issues)  2/5
  :blocked-by (blocked-by)  #9,owner/repo#11 (open issues)
  :blocking (blocking)      #14 (open issues)
  :title, :title-link       text, link (title)
  :milestone (milestone)    1.2.3
  :tags (tags)              :bug:ui:
  :author (author)          @octocat
  :assignee (assignee)      @octocat,@github
  :reviewer (reviewer)      @octocat
  :project (project)        project title
  :project-status (status)  Todo, In Progress
  :classic-project, :classic-project-status
  :created-at, :updated-at, :closed-at, :merged-at

OM-DASH-GITHUB TITLE TEMPLATE

:title-template is a list of parts: :column (its cell text) or
(“FORMAT“ :column).  Parts with empty text are left out; the list must end
with :title; used columns are fetched even if not displayed; sub-issue
nesting goes before.  E.g.:

  :title-template ((“[%s] “ :sub-issues) :title)   =>   [2/5] Set up cluster

OM-DASH-ORGFILE

  :file    Path to .org file.
           Required.
  :query   Simple query (plist), org-ql sexp or org-ql string.
           Default: (:todo-depth 2 :done-depth 1).
  :digest  One table with all entries.

Simple query properties: :todo-depth, :done-depth, :category,
:no-category, :priority, :no-priority, :tag, :every-tag, :no-tag,
:blocked and :habit (`any', `yes', `no').  Columns: :state, :title,
:title-link, :tags.

OM-DASH-IMAP

  :folder  Folder, e.g. “foo/bar“.
           Required.
  :server  Connection plist.
           Default: `om-dash-imap-default-server'.

:server properties: :host (required), :port, :machine (default :host),
:user and :password (default: ~/.authinfo by :machine), :stream, :auth.
Columns: :state, :new, :unread, :total, :folder.

OM-DASH-COMMAND AND OM-DASH-FUNCTION

  :command  Shell command (om-dash-command).
            Required.
  :columns  Column names, list of strings (om-dash-command).
            Required.
  :format   `json' or `csv' (om-dash-command; csv needs parse-csv).
            Default: `json'.
  :func     Function returning tables (om-dash-function).
            Required.
  :args     Function arguments (om-dash-function).

The function returns a list of plists with :columns, :data (rows of
strings), and optional :keyword and :headline.

HEADING PROPERTIES AND MARKERS

  :OM_DASH_HEADING: t     The block sets todo keyword of the heading it's
                          under (TODO if it has open items).
  {/} or {%} in title     With OM_DASH_HEADING: replaced with progress,
                          e.g. {4/6}, {67%}.
  :OM_DASH_STATUS_FACES:  “Status“ face-or-color pairs for status cells;
                          inherited; also “#+PROPERTY:“ for a whole file.

Progress of github blocks: done items (CLOSED or MERGED, or status in
:done-statuses) of all items; each item counts once, sub-issues included.
Om-dash never inserts or renames headings.  E.g.:

  ** TODO Cluster work {/}
  :PROPERTIES:
  :OM_DASH_HEADING: t
  :OM_DASH_STATUS_FACES: “Todo“ “gray60“ “In Progress“ warning
  :END:

FORGE COMMANDS

Commands work on the item of the table row at point (found from the
first link on the row); the backend is chosen by the enclosing block.
Prefix: `om-dash-mode-prefix-key'.

%KEYS%
GitHub columns changed by `om-dash-forge-set-field':

  state       OPEN, or CLOSED: completed / not planned / duplicate.
  title       Title (drafts too).
  status      Project status option.
  tags        Labels.
  assignee    Assignees (drafts too).
  reviewer    Requested reviewers (pull requests).
  milestone   Open milestone; empty removes it.
  parent      Issue number or URL; empty removes it.
  blocked-by  Issues blocking this one.

Other columns can't be changed (an error); instead of “blocking“, set
“blocked-by“ of the blocked issue.

Creating from a typed row (`om-dash-forge-create-item') reads cells by
header: title (required), repo, assignee, tags, milestone, parent,
blocked-by, blocking, status.  Type issue references as plain text
(#12, owner/repo#12, URL), not as links.  Token scopes: “read:project“
(project mode), “project“ (changes).
"
  "Text of `om-dash-help'; “%KEYS%“ is replaced with key bindings.")

(defun om-dash--help-keys ()
  "Return lines describing commands of `om-dash-command-map'."
  (let (commands)
    (map-keymap (lambda (_event command)
                  (when (commandp command)
                    (push command commands)))
                om-dash-command-map)
    (mapconcat
     (lambda (command)
       (format "  %-12s `%s'\n               %s\n"
               (substitute-command-keys
                (format "\\<om-dash-mode-map>\\[%s]" command))
               command
               (car (split-string (or (documentation command t) "") "\n"))))
     (seq-sort-by #'symbol-name #'string< commands)
     "")))

;;;###autoload
(defun om-dash-help ()
  "Show reference of om-dash settings and keys in a help buffer.
Lists block parameters, drawer properties and heading markers, which
are written in org files, and key bindings of `om-dash-command-map'."
  (interactive)
  (help-setup-xref (list #'om-dash-help) (called-interactively-p 'interactive))
  (with-help-window (help-buffer)
    (let ((keys (om-dash--help-keys)))
      ;; like docstrings: `symbol' quotes are shown per `text-quoting-style'
      (princ (substitute-command-keys
              (string-replace "%KEYS%" keys om-dash--help-text))))))

;; “C-c C-. ?“ (see `om-dash-mode-prefix-key')
(define-key om-dash-command-map (kbd "?") #'om-dash-help)

(provide 'om-dash-help)
;;; om-dash-help.el ends here
