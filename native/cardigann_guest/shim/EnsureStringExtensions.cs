using System.Diagnostics;

namespace NzbDrone.Common.EnsureThat
{
    // Upstream EnsureStringExtensions also validates file system paths, which
    // drags in PathExtensions, IAppFolderInfo and OsInfo. Only the non-path
    // checks are kept, with the same behavior and messages.
    [DebuggerStepThrough]
    public static class EnsureStringExtensions
    {
        [DebuggerStepThrough]
        public static Param<string> IsNotNullOrWhiteSpace(this Param<string> param)
        {
            if (string.IsNullOrWhiteSpace(param.Value))
            {
                throw ExceptionFactory.CreateForParamValidation(param.Name, Resources.ExceptionMessages.EnsureExtensions_IsNotNullOrWhiteSpace);
            }

            return param;
        }
    }
}
