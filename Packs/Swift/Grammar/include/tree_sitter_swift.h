/**
    @file tree_sitter_swift.h
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief The Swift grammar's entry point, for the pack's Swift code.
*/

#ifndef TREE_SITTER_SWIFT_H
#define TREE_SITTER_SWIFT_H

typedef struct TSLanguage TSLanguage;

/// The Swift grammar
const TSLanguage *tree_sitter_swift(void);

#endif
