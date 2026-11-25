/**
    @file tree_sitter_rust.h
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief The Rust grammar's entry point, for the pack's Swift code.
*/

#ifndef TREE_SITTER_RUST_H
#define TREE_SITTER_RUST_H

typedef struct TSLanguage TSLanguage;

/// The Rust grammar
const TSLanguage *tree_sitter_rust(void);

#endif
