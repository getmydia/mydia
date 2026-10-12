using System;
using System.Threading;
using System.Threading.Tasks;

namespace Mydia.CardigannGuest.Shim
{
    // The guest has no event loop and no second thread, so a timer never fires
    // and the blocking wait on a pending Task.Delay throws
    // PlatformNotSupportedException. Polly waits between retries with
    // TimeProvider.Delay, which is built on CreateTimer; this provider's timers
    // sleep the calling thread for the due time and then run the callback before
    // CreateTimer returns, so the delay's task is already complete when awaited.
    // The wait is as long as upstream's, only taken with the thread blocked.
    public sealed class BlockingTimeProvider : TimeProvider
    {
        public static readonly BlockingTimeProvider Instance = new();

        // Replaceable so tests do not wait out upstream's retry delays.
        public static Action<TimeSpan> Sleep { get; set; } = Thread.Sleep;

        public override ITimer CreateTimer(TimerCallback callback, object state, TimeSpan dueTime, TimeSpan period) =>
            new BlockingTimer(callback, state, dueTime);

        private sealed class BlockingTimer : ITimer
        {
            public BlockingTimer(TimerCallback callback, object state, TimeSpan dueTime)
            {
                if (dueTime != Timeout.InfiniteTimeSpan)
                {
                    if (dueTime > TimeSpan.Zero)
                    {
                        Sleep(dueTime);
                    }

                    callback(state);
                }
            }

            public bool Change(TimeSpan dueTime, TimeSpan period) => false;

            public void Dispose()
            {
            }

            public ValueTask DisposeAsync() => default;
        }
    }
}
