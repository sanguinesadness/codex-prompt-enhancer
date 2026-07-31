import { EventEmitter } from "node:events";

export interface ProcessTerminationTimer {
  unref?(): void;
}

export interface TerminableChildProcess
  extends Pick<
    EventEmitter,
    "once" | "removeListener"
  > {
  readonly exitCode: number | null;
  readonly signalCode: NodeJS.Signals | null;
  kill(signal: NodeJS.Signals): boolean;
}

export interface ProcessTerminationScheduler {
  readonly setTimeout: (
    callback: () => void,
    delayMilliseconds: number,
  ) => ProcessTerminationTimer;
  readonly clearTimeout: (
    handle: ProcessTerminationTimer,
  ) => void;
}

const defaultScheduler:
  ProcessTerminationScheduler = {
    setTimeout: (
      callback: () => void,
      delayMilliseconds: number,
    ) => setTimeout(
      callback,
      delayMilliseconds,
    ),
    clearTimeout: (
      handle: ProcessTerminationTimer,
    ) => clearTimeout(
      handle as ReturnType<typeof setTimeout>,
    ),
  };

export class ProcessTerminationController {
  private escalationTimer:
    ProcessTerminationTimer | undefined;
  private terminationRequested = false;
  private disposed = false;

  private readonly handleCompletion = (): void => {
    this.dispose();
  };

  public constructor(
    private readonly child:
      TerminableChildProcess,
    private readonly gracePeriodMilliseconds:
      number,
    private readonly scheduler =
      defaultScheduler,
  ) {
    child.once("close", this.handleCompletion);
    child.once("error", this.handleCompletion);
  }

  public requestTermination(): void {
    if (
      this.disposed
      || this.terminationRequested
      || this.hasExited()
    ) {
      return;
    }

    this.terminationRequested = true;
    this.child.kill("SIGTERM");

    this.escalationTimer =
      this.scheduler.setTimeout(
        () => {
          this.escalationTimer = undefined;

          if (
            !this.disposed
            && !this.hasExited()
          ) {
            this.child.kill("SIGKILL");
          }
        },
        this.gracePeriodMilliseconds,
      );

    this.escalationTimer.unref?.();
  }

  public dispose(): void {
    if (this.disposed) {
      return;
    }

    this.disposed = true;
    this.child.removeListener(
      "close",
      this.handleCompletion,
    );
    this.child.removeListener(
      "error",
      this.handleCompletion,
    );

    if (this.escalationTimer !== undefined) {
      this.scheduler.clearTimeout(
        this.escalationTimer,
      );
      this.escalationTimer = undefined;
    }
  }

  private hasExited(): boolean {
    return this.child.exitCode !== null
      || this.child.signalCode !== null;
  }
}
