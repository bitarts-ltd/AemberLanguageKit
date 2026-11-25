/**
    @file tree_sitter_cpp.h
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief The CFamily grammar's entry point, for the pack's Swift code.
*/

#ifndef TREE_SITTER_CPP_H
#define TREE_SITTER_CPP_H

typedef struct TSLanguage TSLanguage;

/// The CFamily grammar
const TSLanguage *tree_sitter_cpp(void);

#endif
