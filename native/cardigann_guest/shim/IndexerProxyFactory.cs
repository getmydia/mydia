using NzbDrone.Core.ThingiProvider;

namespace NzbDrone.Core.IndexerProxies
{
    // Interface half of upstream IndexerProxyFactory.cs.
    public interface IIndexerProxyFactory : IProviderFactory<IIndexerProxy, IndexerProxyDefinition>
    {
    }
}
