;;; -*- lexical-binding:t -*-
;;
;; Usage:
;;
;; (require 'burrmill-helpers
;;          (expand-file-name "~/work/burrmill/maint/emacs-helpers") t)

(require 'cl-macs)
(require 'thingatpt)

(defun kkm:wrap-region-with-colorizers (a b &optional noquote)
  "Wrap the span between A and B with colorizers: $(C c)[selection]$(C).

When called interactively, A and B are endpoint of the active
region, and NOQUOTE is assigned the prefix.

Besides wrapping, add single quotes around the selection, unless
NOQUOTE is non-nil, or quotes are already present right outside
the region.

After the command is completed, the argument 'c' to the first $(C c)
becomes the new region, ready to overtype if other color symbol than
the default 'c' is desired. The result may look like this:

  $(C|c.)'selection'$(C).

where the '.' stands for the new marks, '|' for the new point,
and the region is active, highlighting the 'c'. Type \\[pop-to-mark-command]
twice to jump right past the trailing '$(C)'."
  (interactive "*r\nP")
  (or executing-kbd-macro
      noninteractive
      (region-active-p)
      (user-error "Select text to wrap: $(C c)<selected-text>$(C)"))
  (cl-psetq a (min a b)
            b (max a b))
  ;; (insert) sets 'deactivate-mark' to t. Blargh!
  (let (deactivate-mark)
    ;; Tail first, otherwise 'b' would be invalidated.
    (goto-char b)
    (insert "$(C)")
    (or noquote
        (eq ?' (char-after))
        (insert ?'))
    (push-mark) ; Mark the spot to jump past the string.
    ;; Head last.
    (goto-char a)
    (or noquote
        (eq ?' (char-after (1- (point))))
        (insert ?'))
    (insert "$(C c)"))
  ;; Highlight the 'c'.
  (push-mark (1- (goto-char (1- (point)))) t t))

(define-key (current-global-map) (kbd "C-(") 'kkm:wrap-region-with-colorizers)

(provide 'burrmill-helpers)
