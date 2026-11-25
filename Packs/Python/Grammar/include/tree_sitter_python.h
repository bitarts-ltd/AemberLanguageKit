/**
    @file tree_sitter_python.h
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief The Python grammar's entry point, for the pack's Swift code.
*/

#ifndef TREE_SITTER_PYTHON_H
#define TREE_SITTER_PYTHON_H

typedef struct TSLanguage TSLanguage;

/// The Python grammar
const TSLanguage *tree_sitter_python(void);

#endif
