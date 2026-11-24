/**
    @file tree_sitter_typescript.h
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief The TypeScript grammar's entry point, for the pack's Swift code.
*/

#ifndef TREE_SITTER_TYPESCRIPT_H
#define TREE_SITTER_TYPESCRIPT_H

typedef struct TSLanguage TSLanguage;

/// The TypeScript grammar
const TSLanguage *tree_sitter_typescript(void);

#endif
