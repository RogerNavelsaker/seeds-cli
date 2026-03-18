{ bun2nix, lib, makeWrapper, symlinkJoin }:

let
  manifest = builtins.fromJSON (builtins.readFile ./package-manifest.json);
  licenseMap = {
    "MIT" = lib.licenses.mit;
    "Apache-2.0" = lib.licenses.asl20;
    "SEE LICENSE IN README.md" = lib.licenses.unfree;
  };
  resolvedLicense =
    if builtins.hasAttr manifest.meta.licenseSpdx licenseMap
    then licenseMap.${manifest.meta.licenseSpdx}
    else lib.licenses.unfree;
  allowedBinPattern = lib.concatStringsSep "|" ([ manifest.binary.name ] ++ (manifest.binary.aliases or [ ]));
  aliasWrappers = lib.concatMapStrings
    (
      alias:
      ''
        makeWrapper "$out/bin/${manifest.binary.name}" "$out/bin/${alias}"
      ''
    )
    (manifest.binary.aliases or [ ]);
  pruneBins = ''
    for binPath in "$out/bin/"*; do
      [ -e "$binPath" ] || continue
      binName="$(basename "$binPath")"
      case "$binName" in
        ${allowedBinPattern}) ;;
        *) rm -f "$binPath" ;;
      esac
    done
  '';
  geminiPatch = lib.optionalString (manifest.package.repo == "gemini-cli") ''
    geminiNodeModules="$out/share/${manifest.package.repo}/node_modules"
    shellExecutionService="$(find "$geminiNodeModules" -path '*gemini-cli-core*/dist/src/services/shellExecutionService.js' | head -n 1)"
    retryJs="$(find "$geminiNodeModules" -path '*gemini-cli-core*/dist/src/utils/retry.js' | head -n 1)"
    shellToolMessage="$(find "$geminiNodeModules" -path '*gemini-cli*/dist/src/ui/components/messages/ShellToolMessage.js' | head -n 1)"
    backgroundShellDisplay="$(find "$geminiNodeModules" -path '*gemini-cli*/dist/src/ui/components/BackgroundShellDisplay.js' | head -n 1)"
    nodePtyUnix="$(find "$geminiNodeModules" -path '*@lydell/node-pty/unixTerminal.js' | head -n 1)"

    if [ -f "$shellExecutionService" ]; then
      substituteInPlace "$shellExecutionService" \
        --replace-fail "const isEsrch = err.code === 'ESRCH';" "const isEsrch = err.code === 'ESRCH';
                const isEbadf = err.code === 'EBADF' || err.message?.includes('EBADF');" \
        --replace-fail "if (isEsrch || isWindowsPtyError) {" "if (isEsrch || isEbadf || isWindowsPtyError) {" \
        --replace-fail "// On Unix, we get an ESRCH error." "// On Unix, we get an ESRCH error or an EBADF from a closed fd."
    fi

    if [ -f "$shellToolMessage" ]; then
      substituteInPlace "$shellToolMessage" \
        --replace-fail "if (!(e instanceof Error &&
                    e.message.includes('Cannot resize a pty that has already exited'))) {" "if (!(e instanceof Error &&
                    (e.message.includes('Cannot resize a pty that has already exited') ||
                        e.message.includes('EBADF') ||
                        e.code === 'EBADF' ||
                        e.code === 'ESRCH'))) {"
    fi

    if [ -f "$backgroundShellDisplay" ]; then
      substituteInPlace "$backgroundShellDisplay" \
        --replace-fail "        ShellExecutionService.resizePty(activePid, ptyWidth, ptyHeight);" "        try {
            ShellExecutionService.resizePty(activePid, ptyWidth, ptyHeight);
        }
        catch (e) {
            if (!(e instanceof Error &&
                (e.message.includes('Cannot resize a pty that has already exited') ||
                    e.message.includes('EBADF') ||
                    e.code === 'EBADF' ||
                    e.code === 'ESRCH'))) {
                throw e;
            }
        }"
    fi

    if [ -f "$retryJs" ]; then
      substituteInPlace "$retryJs" \
        --replace-fail "export const DEFAULT_MAX_ATTEMPTS = 10;" "export const DEFAULT_MAX_ATTEMPTS = 1000;" \
        --replace-fail "    initialDelayMs: 5000," "    initialDelayMs: 1000," \
        --replace-fail "    maxDelayMs: 30000, // 30 seconds" "    maxDelayMs: 5000, // 5 seconds max between retries"

      oldRetryBlock=$(cat <<'EOF'
            if (classifiedError instanceof TerminalQuotaError ||
                classifiedError instanceof ModelNotFoundError) {
                if (onPersistent429) {
                    try {
                        const fallbackModel = await onPersistent429(authType, classifiedError);
                        if (fallbackModel) {
                            attempt = 0; // Reset attempts and retry with the new model.
                            currentDelay = initialDelayMs;
                            continue;
                        }
                    }
                    catch (fallbackError) {
                        debugLogger.warn('Fallback to Flash model failed:', fallbackError);
                    }
                }
                // Terminal/not_found already recorded; nothing else to mark here.
                throw classifiedError; // Throw if no fallback or fallback failed.
            }
EOF
      )
      newRetryBlock=$(cat <<'EOF'
            if (classifiedError instanceof ModelNotFoundError) {
                throw classifiedError; // Model genuinely doesn't exist, no point retrying.
            }
            // PATCHED: treat TerminalQuotaError as retryable
            if (classifiedError instanceof TerminalQuotaError) {
                if (attempt >= maxAttempts) {
                    if (onPersistent429) {
                        try {
                            const fallbackModel = await onPersistent429(authType, classifiedError);
                            if (fallbackModel) {
                                attempt = 0;
                                currentDelay = initialDelayMs;
                                continue;
                            }
                        }
                        catch (fallbackError) {
                            debugLogger.warn('Fallback failed:', fallbackError);
                        }
                    }
                    throw classifiedError;
                }
                const jitter = currentDelay * 0.3 * (Math.random() * 2 - 1);
                const delayWithJitter = Math.max(0, currentDelay + jitter);
                debugLogger.warn(`Attempt ''${attempt} hit quota limit: ''${classifiedError.message}. Retrying in ''${Math.round(delayWithJitter)}ms...`);
                if (onRetry) {
                    onRetry(attempt, classifiedError, delayWithJitter);
                }
                await delay(delayWithJitter, signal);
                currentDelay = Math.min(maxDelayMs, currentDelay * 2);
                continue;
            }
EOF
      )
      substituteInPlace "$retryJs" --replace-fail "$oldRetryBlock" "$newRetryBlock"
    fi

    if [ -f "$nodePtyUnix" ]; then
      oldUnixResize=$(cat <<'EOF'
    UnixTerminal.prototype.resize = function (cols, rows) {
        if (cols <= 0 || rows <= 0 || isNaN(cols) || isNaN(rows) || cols === Infinity || rows === Infinity) {
            throw new Error('resizing must be done using positive cols and rows');
        }
        pty.resize(this._fd, cols, rows);
        this._cols = cols;
        this._rows = rows;
    };
EOF
      )
      newUnixResize=$(cat <<'EOF'
    UnixTerminal.prototype.resize = function (cols, rows) {
        // PATCHED: catch EBADF from native pty.resize
        if (cols <= 0 || rows <= 0 || isNaN(cols) || isNaN(rows) || cols === Infinity || rows === Infinity) {
            throw new Error('resizing must be done using positive cols and rows');
        }
        try {
            pty.resize(this._fd, cols, rows);
        }
        catch (e) {
            if (e && (e.message?.includes('EBADF') || e.message?.includes('ESRCH') || e.code === 'EBADF' || e.code === 'ESRCH')) {
                return;
            }
            throw e;
        }
        this._cols = cols;
        this._rows = rows;
    };
EOF
      )
      substituteInPlace "$nodePtyUnix" --replace-fail "$oldUnixResize" "$newUnixResize"
    fi
  '';
  basePackage = bun2nix.writeBunApplication {
  pname = manifest.package.repo;
  version = manifest.package.version;
  packageJson = ../package.json;
  src = lib.cleanSource ../.;
  dontUseBunBuild = true;
  dontUseBunCheck = true;
  startScript = ''
    bunx ${manifest.binary.upstreamName or manifest.binary.name} "$@"
  '';
  bunDeps = bun2nix.fetchBunDeps {
    bunNix = ../bun.nix;
  };
  postInstall = ''
    ${geminiPatch}
  '';
  meta = with lib; {
    description = manifest.meta.description;
    homepage = manifest.meta.homepage;
    license = resolvedLicense;
    mainProgram = manifest.binary.name;
    platforms = platforms.linux ++ platforms.darwin;
    broken = manifest.stubbed || !(builtins.pathExists ../bun.nix);
  };
  };
in
symlinkJoin {
  name = "${manifest.binary.name}-${manifest.package.version}";
  paths = [ basePackage ];
  nativeBuildInputs = [ makeWrapper ];
  postBuild = ''
    rm -rf "$out/bin"
    mkdir -p "$out/bin"
    makeWrapper "${basePackage}/bin/${manifest.package.repo}" "$out/bin/${manifest.binary.name}"
    ${aliasWrappers}
  '';
  meta = basePackage.meta;
}
