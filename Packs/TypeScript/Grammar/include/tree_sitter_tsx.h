/**
    @file tree_sitter_tsx.h
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief The TypeScript grammar's entry point, for the pack's Swift code.
*/

#ifndef TREE_SITTER_TSX_H
#define TREE_SITTER_TSX_H

typedef struct TSLanguage TSLanguage;

/// The TypeScript grammar
const TSLanguage *tree_sitter_tsx(void);

#endif
