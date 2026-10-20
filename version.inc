; ============================================================================
; ASM Terminal version - the single source of truth.
; Semantic versioning: MAJOR.MINOR.PATCH
;   MAJOR - breaking changes (commands or config that stop working)
;   MINOR - new features that keep old behaviour
;   PATCH - bug fixes only
; Bump this, add a CHANGELOG.md entry, then tag the release vX.Y.Z.
; The Makefile, release workflow and 'update' command all read it.
; ============================================================================
%ifndef ASM_VERSION
    %define ASM_VERSION "2.2.0"
%endif
