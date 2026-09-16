# Host lifecycle and recovery

- **Host Lifecycle & TCC Staging Workflow**:
  1. **Stage Once**: `./bin/agy-computer-use stage-host-app` builds and stages the canonical `ComputerUseHost.app` bundle.
  2. **Grant TCC Authority**: With the owned host stopped, use `./bin/agy-computer-use host-start --request-accessibility` only when Accessibility enrollment is needed, then let the operator approve the macOS prompt or toggle. Ordinary `host-start` is prompt-silent.
  3. **Restart Without Restaging**: `./bin/agy-computer-use host-stop && ./bin/agy-computer-use host-start`. Cold starts launch the already-staged app without rebuilding, replacing, or resigning it, preserving filesystem identity (inodes and mtime), executable bytes (SHA-256), and the app signing identity (CDHash).
  4. **Verify MCP Operations**: Call `computer_use_status` and `computer_use_observe` over MCP.
- **Host Lifecycle Management**:
  - `./bin/agy-computer-use stage-host-app`: Builds and stages the canonical `ComputerUseHost.app` bundle.
  - `./bin/agy-computer-use host-start`: Starts the background native host process using the already-staged canonical app.
  - `./bin/agy-computer-use host-start --request-accessibility`: On a stopped host only, launches the exact staged app with one explicit Accessibility prompt request. Never add this flag to routine starts or bypass the human macOS approval.
  - `./bin/agy-computer-use host-status`: Checks if native host is `running`, `stopped`, or `stale`.
  - `./bin/agy-computer-use host-stop`: Stops the native host process cleanly, awaiting exact native child close and terminal owner receipt (`native_closed: true`).
  - *Process Authority & Security*: Host lifecycle commands communicate with the owner control server on `control.sock` (terminal owner correlation) and strictly enforce the non-override canonical runtime directory policy (`/tmp/agy-computer-use-<uid>`).
