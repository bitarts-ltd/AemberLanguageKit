/**
    @file tree_sitter_c.h
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief The CFamily grammar's entry point, for the pack's Swift code.
*/

#ifndef TREE_SITTER_C_H
#define TREE_SITTER_C_H

typedef struct TSLanguage TSLanguage;

/// The CFamily grammar
const TSLanguage *tree_sitter_c(void);

#endif
