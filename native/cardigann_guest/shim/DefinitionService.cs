using System.Collections.Generic;
using Mydia.CardigannGuest.Shim;
using NzbDrone.Core.Indexers.Definitions.Cardigann;
using YamlDotNet.Serialization;
using YamlDotNet.Serialization.NamingConventions;

namespace NzbDrone.Core.IndexerVersions
{
    public interface IIndexerDefinitionUpdateService
    {
        List<CardigannMetaDefinition> All();
        CardigannDefinition GetCachedDefinition(string fileKey);
        List<string> GetBlocklist();
    }

    // Holds the one definition the host passed into this call.
    public sealed class SingleDefinitionService : IIndexerDefinitionUpdateService
    {
        // Copied from IndexerDefinitionUpdateService at the pinned commit, plus the
        // FilterArgs converter (shim/FilterArgs.cs).
        private static readonly IDeserializer Deserializer = new DeserializerBuilder()
            .IgnoreUnmatchedProperties()
            .WithNamingConvention(CamelCaseNamingConvention.Instance)
            .WithTypeConverter(new FilterArgsConverter())
            .Build();

        private readonly CardigannDefinition _definition;

        public SingleDefinitionService(string yaml)
        {
            _definition = Deserializer.Deserialize<CardigannDefinition>(yaml);
        }

        public string FileKey => _definition.Id;

        // CardigannDefinition does not derive from CardigannMetaDefinition at the pin,
        // so the meta entry is projected from the definition.
        public List<CardigannMetaDefinition> All() => new List<CardigannMetaDefinition>
        {
            new CardigannMetaDefinition
            {
                Id = _definition.Id,
                File = _definition.Id,
                Name = _definition.Name,
                Description = _definition.Description,
                Type = _definition.Type,
                Language = _definition.Language,
                Encoding = _definition.Encoding,
                Links = _definition.Links,
                Legacylinks = _definition.Legacylinks,
                Settings = _definition.Settings,
                Login = _definition.Login,
                Caps = _definition.Caps
            }
        };

        public CardigannDefinition GetCachedDefinition(string fileKey) => _definition;

        public List<string> GetBlocklist() => new List<string>();
    }
}
