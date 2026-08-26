# LSF environment for TileBuilder commands (without cbwa_init.csh)
# cbwa and TileBuilder environments are mutually exclusive

# Source LSF without cbwa
source /tool/pandora/etc/lsf/cshrc.lsf
source /tool/site-config/cshrc

# Do NOT source cbwa_init.csh - it conflicts with TileBuilder

# ==========================================================================
# TileBuilderTerm Environment Setup
# ==========================================================================

# CRITICAL FIX: Unset TILEBUILDER_TERM to use default xterm
if ($?TILEBUILDER_TERM) then
    unsetenv TILEBUILDER_TERM
endif

# Preserve X11 environment for GUI applications (required for TileBuilderTerm)
if ($?DISPLAY) then
    setenv DISPLAY $DISPLAY
endif
if ($?XAUTHORITY) then
    setenv XAUTHORITY $XAUTHORITY
endif

# Preserve license environment variables (required for Synopsys tools)
if ($?SNPSLMD_LICENSE_FILE) then
    setenv SNPSLMD_LICENSE_FILE $SNPSLMD_LICENSE_FILE
endif
if ($?LM_LICENSE_FILE) then
    setenv LM_LICENSE_FILE $LM_LICENSE_FILE
endif

# Set TMPDIR for TileBuilderTerm temporary files
if (! $?TMPDIR) then
    setenv TMPDIR /tmp
endif

# Ensure /tmp is writable, fallback to $HOME/tmp if not
if (! -w /tmp) then
    if (! -d $HOME/tmp) then
        mkdir -p $HOME/tmp
    endif
    setenv TMPDIR $HOME/tmp
endif

# Preserve basic shell environment
if ($?HOME) then
    setenv HOME $HOME
endif
if ($?USER) then
    setenv USER $USER
endif
if ($?SHELL) then
    setenv SHELL $SHELL
endif

# Preserve library and tool paths
if ($?LD_LIBRARY_PATH) then
    setenv LD_LIBRARY_PATH $LD_LIBRARY_PATH
endif
if ($?PATH) then
    setenv PATH $PATH
endif

# ==========================================================================
# End TileBuilderTerm Environment Setup
# ==========================================================================
