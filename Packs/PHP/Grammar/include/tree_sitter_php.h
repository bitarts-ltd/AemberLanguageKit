/**
    @file tree_sitter_php.h
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief The PHP grammar's entry point, for the pack's Swift code.
*/

#ifndef TREE_SITTER_PHP_H
#define TREE_SITTER_PHP_H

typedef struct TSLanguage TSLanguage;

/// The PHP grammar without embedded HTML (tree-sitter-php's php_only)
const TSLanguage *tree_sitter_php_only(void);

#endif
