/**
    @file tree_sitter_javascript.h
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief The TypeScript grammar's entry point, for the pack's Swift code.
*/

#ifndef TREE_SITTER_JAVASCRIPT_H
#define TREE_SITTER_JAVASCRIPT_H

typedef struct TSLanguage TSLanguage;

/// The TypeScript grammar
const TSLanguage *tree_sitter_javascript(void);

#endif
