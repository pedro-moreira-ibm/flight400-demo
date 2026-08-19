#!/QOpenSys/pkgs/bin/bash
# =============================================================================
# setup_flight400_lab.sh
# =============================================================================
# PURPOSE
#   One-shot setup for the FLIGHT400 IBM i modernization lab. Replaces the
#   manual "run Install-Flight400.sql, then ask Bob to CPYLIB N times" flow.
#
#   Two phases (either can be skipped):
#     PHASE 1 - RESTORE the master library FLGHT400 from a save file that was
#               uploaded to the IFS  (CRTSAVF -> CPYFRMSTMF -> RSTLIB -> CHGOWN)
#     PHASE 2 - CLONE  the master into FLGHT401..FLGHT4nn, one per attendee,
#               using CPYLIB. Suffix is zero-padded to 2 digits so the naming
#               matches the FLGHT4nn / port 30nn convention in the lab guide.
#
#   Run this ON the IBM i (PASE bash), e.g. from an SSH/QSH session, once,
#   before the workshop. Designed for 20+ attendees without touching Bob.
#
# USAGE
#   bash setup_flight400_lab.sh --savf-path <IFS_PATH> --participants <N> [OPTIONS]
#
# REQUIRED (unless --skip-restore)
#   -f, --savf-path PATH   IFS path to the uploaded FLGHT400.FILE
#                          e.g. /home/ITZUSER/builds/flight400/FLGHT400.FILE
#
# COUNT (choose one)
#   -n, --participants N   Create FLGHT401 .. FLGHT4<N>   (e.g. 20 -> ..FLGHT420)
#   -r, --range M N        Explicit inclusive suffix range (e.g. 1 24)
#
# OPTIONS
#       --master LIB       Master library to restore/clone from   (default FLGHT400)
#       --base BASE        Base name for the clones                (default FLGHT4)
#       --savf NAME        Save-file object name in QGPL           (default FLIGHT400)
#       --savlib LIB       SAVLIB name INSIDE the save file        (default FLGHT400)
#       --owner PROFILE    Owner for the restored master          (default: current user)
#       --chgown-clones    Also transfer ownership of each clone   (default: off)
#       --skip-restore     Skip phase 1 (master already restored)
#       --restore-only     Do phase 1 only, no clones
#       --force            Overwrite existing master / clone libraries
#   -d, --dry-run          Print the CL commands without running them
#   -v, --verbose          Show full CL command output
#   -h, --help             Show this help
#
# EXAMPLES
#   # Full setup for 20 people (restore master + FLGHT401..FLGHT420)
#   bash setup_flight400_lab.sh -f /home/ITZUSER/builds/flight400/FLGHT400.FILE -n 20
#
#   # Master already exists -> just clone for 30 people
#   bash setup_flight400_lab.sh --skip-restore -n 30
#
#   # Preview everything, change nothing
#   bash setup_flight400_lab.sh -f /home/ME/FLGHT400.FILE -n 24 --dry-run
#
#   # Restore only, overwriting an existing master
#   bash setup_flight400_lab.sh -f /home/ME/FLGHT400.FILE --restore-only --force
#
# NOTES
#   - Idempotent: CRTSAVF/RSTLIB are skipped if the object already exists
#     (use --force to drop & rebuild the master or overwrite existing clones).
#   - CPYFRMSTMF uses MBROPT(*REPLACE) so re-uploading the save file is safe.
#   - RSTLIB completing with CPF3773 "0 not restored" and/or CPF3848 "security
#     or data format changes" is treated as SUCCESS - those are informational
#     messages that are normal on a cross-system save/restore.
#   - The -f path is checked for existence before Phase 1 begins (unless
#     --dry-run), so a wrong/typo path stops with a clear error immediately.
#   - Library names are max 10 chars; base+suffix is validated.
#   - CPYLIB copies ALL objects (programs, DDS/source, DB files) in one pass,
#     so every attendee gets a fully independent copy of the application.
#   - Requires authority to CRTSAVF, CPYFRMSTMF, RSTLIB, CHGOWN, CRTLIB,
#     DLTLIB, CPYLIB (typically *ALLOBJ, i.e. the shared lab profile).
# =============================================================================
set -uo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
SAVF_PATH=""
MASTER="FLGHT400"      # restored/cloned-from library
BASE="FLGHT4"          # clone base name  -> FLGHT4 + NN
SAVF="FLIGHT400"       # save-file object name in QGPL (matches Install-Flight400.sql)
SAVLIB="FLGHT400"      # SAVLIB name stored inside the save file
OWNER=""               # empty -> resolved to current user
PAD=2                  # suffix zero-pad width

PARTICIPANTS=""
RANGE_M=""
RANGE_N=""

CHGOWN_CLONES=false
SKIP_RESTORE=false
RESTORE_ONLY=false
FORCE=false
DRY_RUN=false
VERBOSE=false

CLONE_OK=0
CLONE_ERR=0

# Regex of RSTLIB messages that mean "completed successfully" even though the
# CL command returns a non-zero code to the shell. "(^| )0 not restored"
# matches "... 0 not restored" but NOT "... 10 not restored".
RSTLIB_OK_PATTERN='(^| )0 not restored'

# CHGOWN with SUBTREE(*ALL) returns non-zero (CPF223A) because some system-managed
# objects legitimately cannot be reowned - that is expected and harmless. The
# original Install-Flight400.sql ignores CPF223A for exactly this reason.
CHGOWN_OK_PATTERN='CPF223A|objects changed'

# ---------------------------------------------------------------------------
# Colours (disabled when not a terminal)
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
usage() {
    sed -n '/^# USAGE/,/^# NOTES/p' "$0" | sed 's/^#\{0,1\} \{0,1\}//'
    exit 0
}

is_integer() { [[ "$1" =~ ^[0-9]+$ ]]; }

# run_cl <description> <CL command> [ok_pattern]
#   Runs a CL command via the PASE `system` utility.
#   Returns 0 on success, 1 on failure. Never aborts the script.
#   If the command returns non-zero BUT its output matches the optional
#   ok_pattern regex, it is treated as a success (used for RSTLIB, which
#   returns non-zero on CPF3773 even when 0 objects failed to restore).
run_cl() {
    local desc="$1" cmd="$2" ok_pattern="${3:-}" out rc=0
    printf "    %-52s" "$desc"
    $VERBOSE && { echo; echo -e "      ${CYAN}${cmd}${RESET}"; printf "    %-52s" ""; }
    if $DRY_RUN; then
        echo -e "${YELLOW}[dry-run]${RESET}"
        return 0
    fi
    out=$(system "$cmd" 2>&1) || rc=$?
    if [ $rc -ne 0 ]; then
        if [ -n "$ok_pattern" ] && echo "$out" | grep -Eq "$ok_pattern"; then
            echo -e "${GREEN}OK${RESET} ${YELLOW}(completed with informational messages)${RESET}"
            $VERBOSE && [ -n "$out" ] && echo -e "      ${out}"
            return 0
        fi
        echo -e "${RED}FAILED${RESET}"
        echo -e "      ${RED}${out}${RESET}" >&2
        return 1
    fi
    echo -e "${GREEN}OK${RESET}"
    $VERBOSE && [ -n "$out" ] && echo -e "      ${out}"
    return 0
}

# lib_exists <lib>  -> 0 if the *LIB exists
lib_exists() {
    system "QSYS/CHKOBJ OBJ(QSYS/${1}) OBJTYPE(*LIB)" >/dev/null 2>&1
}

# obj_exists <lib> <obj> <type>  -> 0 if object exists
obj_exists() {
    system "QSYS/CHKOBJ OBJ(${1}/${2}) OBJTYPE(${3})" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--savf-path)   SAVF_PATH="$2"; shift 2 ;;
        -n|--participants) PARTICIPANTS="$2"; shift 2 ;;
        -r|--range)       RANGE_M="$2"; RANGE_N="$3"; shift 3 ;;
        --master)         MASTER=$(echo "$2" | tr '[:lower:]' '[:upper:]'); shift 2 ;;
        --base)           BASE=$(echo "$2" | tr '[:lower:]' '[:upper:]'); shift 2 ;;
        --savf)           SAVF=$(echo "$2" | tr '[:lower:]' '[:upper:]'); shift 2 ;;
        --savlib)         SAVLIB=$(echo "$2" | tr '[:lower:]' '[:upper:]'); shift 2 ;;
        --owner)          OWNER=$(echo "$2" | tr '[:lower:]' '[:upper:]'); shift 2 ;;
        --chgown-clones)  CHGOWN_CLONES=true; shift ;;
        --skip-restore)   SKIP_RESTORE=true; shift ;;
        --restore-only)   RESTORE_ONLY=true; shift ;;
        --force)          FORCE=true; shift ;;
        -d|--dry-run)     DRY_RUN=true; shift ;;
        -v|--verbose)     VERBOSE=true; shift ;;
        -h|--help)        usage ;;
        *) echo -e "${RED}Unknown option: $1${RESET}"; echo; usage ;;
    esac
done

# ---------------------------------------------------------------------------
# Resolve owner (current PASE user, uppercased) if not supplied
# ---------------------------------------------------------------------------
if [[ -z "$OWNER" ]]; then
    OWNER=$(whoami 2>/dev/null | tr '[:lower:]' '[:upper:]')
    [[ -z "$OWNER" ]] && OWNER=$(id -un 2>/dev/null | tr '[:lower:]' '[:upper:]')
fi
OWNER=${OWNER:0:10}

# ---------------------------------------------------------------------------
# Validate inputs
# ---------------------------------------------------------------------------
errs=0

if ! $SKIP_RESTORE; then
    if [[ -z "$SAVF_PATH" ]]; then
        echo -e "${RED}ERROR: --savf-path is required (or use --skip-restore).${RESET}" >&2
        errs=$((errs+1))
    fi
fi

# Build the clone suffix range (unless restore-only)
TARGETS=()
if ! $RESTORE_ONLY; then
    if [[ -n "$PARTICIPANTS" ]]; then
        if ! is_integer "$PARTICIPANTS" || [[ "$PARTICIPANTS" -lt 1 ]]; then
            echo -e "${RED}ERROR: --participants must be a positive integer.${RESET}" >&2
            errs=$((errs+1))
        else
            RANGE_M=1; RANGE_N="$PARTICIPANTS"
        fi
    fi
    if [[ -z "$RANGE_M" || -z "$RANGE_N" ]]; then
        echo -e "${RED}ERROR: provide --participants N or --range M N (or use --restore-only).${RESET}" >&2
        errs=$((errs+1))
    elif ! is_integer "$RANGE_M" || ! is_integer "$RANGE_N"; then
        echo -e "${RED}ERROR: range values must be integers.${RESET}" >&2
        errs=$((errs+1))
    elif [[ "$RANGE_M" -gt "$RANGE_N" ]]; then
        echo -e "${RED}ERROR: range M must be <= N (got $RANGE_M..$RANGE_N).${RESET}" >&2
        errs=$((errs+1))
    fi
fi

[ $errs -gt 0 ] && exit 1

# Preflight: verify the save file actually exists on the IFS before we start
if ! $SKIP_RESTORE && ! $DRY_RUN; then
    if [[ ! -f "$SAVF_PATH" ]]; then
        echo -e "${RED}ERROR: save file not found at:${RESET}" >&2
        echo -e "       ${SAVF_PATH}" >&2
        echo -e "       Check the path (did you upload it?), or run:" >&2
        echo -e "         find /home -name '${SAVF##*/}.FILE' 2>/dev/null" >&2
        echo -e "       Tip: pass an absolute path starting with '/'." >&2
        exit 1
    fi
fi

# Grow pad width if the top suffix needs more than 2 digits, then validate 10-char limit
if ! $RESTORE_ONLY; then
    top_len=${#RANGE_N}
    [ "$top_len" -gt "$PAD" ] && PAD=$top_len
    if [ $((${#BASE} + PAD)) -gt 10 ]; then
        echo -e "${RED}ERROR: base '$BASE' + ${PAD}-digit suffix exceeds the 10-char library limit.${RESET}" >&2
        exit 1
    fi
    for (( i=RANGE_M; i<=RANGE_N; i++ )); do
        TARGETS+=( "${BASE}$(printf "%0${PAD}d" "$i")" )
    done
fi

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
echo
echo -e "${BOLD}============================================================${RESET}"
echo -e "${BOLD}  FLIGHT400 Lab Setup${RESET}"
echo -e "${BOLD}============================================================${RESET}"
echo -e "  Master library : ${CYAN}${MASTER}${RESET}"
$SKIP_RESTORE || echo -e "  Save file      : QGPL/${SAVF}  (SAVLIB ${SAVLIB})"
$SKIP_RESTORE || echo -e "  IFS save file  : ${SAVF_PATH}"
echo -e "  Owner          : ${OWNER}"
if ! $RESTORE_ONLY; then
    echo -e "  Clones         : ${CYAN}${TARGETS[0]} .. ${TARGETS[-1]}${RESET}  (${#TARGETS[@]} total)"
fi
$SKIP_RESTORE  && echo -e "  Mode           : ${YELLOW}skip restore (clone only)${RESET}"
$RESTORE_ONLY  && echo -e "  Mode           : ${YELLOW}restore only (no clones)${RESET}"
$FORCE         && echo -e "  Overwrite      : ${YELLOW}FORCE${RESET}"
$DRY_RUN       && echo -e "  Mode           : ${YELLOW}DRY-RUN (no changes)${RESET}"
echo

# ===========================================================================
# PHASE 1 - Restore the master library from the save file
# ===========================================================================
if ! $SKIP_RESTORE; then
    echo -e "${BOLD}[Phase 1] Restore master ${MASTER} from save file${RESET}"

    # 1. Create the save file in QGPL (skip if it already exists)
    if ! $DRY_RUN && obj_exists "QGPL" "$SAVF" "*FILE"; then
        printf "    %-52s%s\n" "Create save file QGPL/${SAVF}" "${GREEN}exists${RESET}"
    else
        run_cl "Create save file QGPL/${SAVF}" \
               "QSYS/CRTSAVF FILE(QGPL/${SAVF})" || exit 1
    fi

    # 2. Copy the uploaded IFS stream file into the QSYS save file (replace on re-run)
    run_cl "Copy IFS -> QGPL/${SAVF}" \
           "QSYS/CPYFRMSTMF FROMSTMF('${SAVF_PATH}') TOMBR('/QSYS.LIB/QGPL.LIB/${SAVF}.FILE') MBROPT(*REPLACE)" \
           || exit 1

    # 3. Restore the library (drop first if --force, else skip when it already exists)
    #    RSTLIB returns non-zero on CPF3773 even when everything restored, so we
    #    pass RSTLIB_OK_PATTERN ("0 not restored") to treat that as success.
    if lib_exists "$MASTER" && ! $DRY_RUN; then
        if $FORCE; then
            run_cl "Delete existing ${MASTER} (force)" "QSYS/DLTLIB LIB(${MASTER})" || exit 1
            run_cl "Restore library -> ${MASTER}" \
                   "QSYS/RSTLIB SAVLIB(${SAVLIB}) DEV(*SAVF) SAVF(QGPL/${SAVF}) RSTLIB(${MASTER})" \
                   "$RSTLIB_OK_PATTERN" || exit 1
        else
            printf "    %-52s%s\n" "Restore library -> ${MASTER}" \
                   "${YELLOW}skipped (exists; use --force)${RESET}"
        fi
    else
        run_cl "Restore library -> ${MASTER}" \
               "QSYS/RSTLIB SAVLIB(${SAVLIB}) DEV(*SAVF) SAVF(QGPL/${SAVF}) RSTLIB(${MASTER})" \
               "$RSTLIB_OK_PATTERN" || exit 1
    fi

    # Safety net: confirm the master library actually exists before continuing
    if ! $DRY_RUN && ! lib_exists "$MASTER"; then
        echo -e "  ${RED}ERROR: ${MASTER} was not restored - stopping.${RESET}" >&2
        exit 1
    fi

    # 4. Transfer ownership: the library object + everything inside it.
    #    CHGOWN SUBTREE(*ALL) returns non-zero via CPF223A because some system
    #    objects can't be reowned - pass CHGOWN_OK_PATTERN to treat that as OK.
    run_cl "Chgown library object -> ${OWNER}" \
           "QSYS/CHGOWN OBJ('/QSYS.LIB/${MASTER}.LIB') NEWOWN(${OWNER})" \
           "$CHGOWN_OK_PATTERN" || true
    run_cl "Chgown library contents -> ${OWNER}" \
           "QSYS/CHGOWN OBJ('/QSYS.LIB/${MASTER}.LIB/*') NEWOWN(${OWNER}) SUBTREE(*ALL)" \
           "$CHGOWN_OK_PATTERN" || true

    echo -e "  ${GREEN}Master ${MASTER} ready.${RESET}"
    echo
fi

if $RESTORE_ONLY; then
    echo -e "${GREEN}Done - restore-only requested, no clones created.${RESET}"
    echo
    exit 0
fi

# ===========================================================================
# PHASE 2 - Clone the master into FLGHT4nn, one per attendee
# ===========================================================================
echo -e "${BOLD}[Phase 2] Clone ${MASTER} -> ${#TARGETS[@]} attendee libraries${RESET}"

# Verify the master exists before cloning
if ! $DRY_RUN && ! lib_exists "$MASTER"; then
    echo -e "  ${RED}ERROR: master library ${MASTER} not found. Run without --skip-restore first.${RESET}" >&2
    exit 1
fi

idx=0
total=${#TARGETS[@]}
for TGT in "${TARGETS[@]}"; do
    idx=$((idx+1))
    echo -e "  ${BOLD}[$idx/$total]${RESET} ${MASTER} -> ${TGT}"

    # Handle an existing target
    if ! $DRY_RUN && lib_exists "$TGT"; then
        if $FORCE; then
            run_cl "Delete existing ${TGT} (force)" "QSYS/DLTLIB LIB(${TGT})" || {
                CLONE_ERR=$((CLONE_ERR+1)); echo; continue; }
        else
            printf "    %-52s%s\n" "Clone ${TGT}" "${YELLOW}skipped (exists; use --force)${RESET}"
            echo; continue
        fi
    fi

    if run_cl "CPYLIB ${MASTER} -> ${TGT}" \
              "QSYS/CPYLIB FROMLIB(${MASTER}) TOLIB(${TGT}) CRTLIB(*YES)"; then
        if $CHGOWN_CLONES; then
            run_cl "Chgown ${TGT} contents -> ${OWNER}" \
                   "QSYS/CHGOWN OBJ('/QSYS.LIB/${TGT}.LIB/*') NEWOWN(${OWNER}) SUBTREE(*ALL)" \
                   "$CHGOWN_OK_PATTERN" || true
        fi
        CLONE_OK=$((CLONE_OK+1))
    else
        CLONE_ERR=$((CLONE_ERR+1))
    fi
    echo
done

# ===========================================================================
# Summary + attendee assignment table
# ===========================================================================
echo -e "${BOLD}============================================================${RESET}"
if $DRY_RUN; then
    echo -e "  ${YELLOW}DRY-RUN complete - no changes were made.${RESET}"
elif [ $CLONE_ERR -eq 0 ]; then
    echo -e "  ${GREEN}ALL DONE - ${CLONE_OK} attendee libraries cloned successfully.${RESET}"
else
    echo -e "  ${YELLOW}DONE with errors - ${CLONE_OK} ok, ${RED}${CLONE_ERR} failed${YELLOW}.${RESET}"
fi
echo -e "${BOLD}============================================================${RESET}"
echo
echo -e "  ${BOLD}Attendee assignments${RESET} (share this with students):"
printf "    %-10s %-10s %-9s %s\n" "Student" "Library" "DevPort" "React App URL"
printf "    %s\n" "-------------------------------------------------------"
n=0
for TGT in "${TARGETS[@]}"; do
    n=$((n+1))
    suffix=${TGT#$BASE}
    printf "    %-10s %-10s %-9s http://localhost:30%s\n" "$n" "$TGT" "30${suffix}" "$suffix"
done
echo
echo -e "  Each attendee: ADDLIBLE <their library>  then  GO <their library>/FRSMAIN"
echo

exit $CLONE_ERR
