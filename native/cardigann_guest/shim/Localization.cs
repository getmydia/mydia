using System.Collections.Generic;

namespace NzbDrone.Core.Localization
{
    // Interface half of upstream LocalizationService.cs.
    public interface ILocalizationService
    {
        Dictionary<string, string> GetLocalizationDictionary();

        string GetLocalizedString(string phrase);
        string GetLocalizedString(string phrase, Dictionary<string, object> tokens);
        IEnumerable<LocalizationOption> GetLocalizationOptions();
    }

    // The guest returns messages in English, as keyed.
    public sealed class EnglishLocalizationService : ILocalizationService
    {
        public Dictionary<string, string> GetLocalizationDictionary() => new Dictionary<string, string>();

        public string GetLocalizedString(string phrase) => phrase;

        public string GetLocalizedString(string phrase, Dictionary<string, object> tokens)
        {
            if (tokens == null)
            {
                return phrase;
            }

            foreach (var token in tokens)
            {
                phrase = phrase.Replace("{" + token.Key + "}", token.Value?.ToString() ?? string.Empty);
            }

            return phrase;
        }

        public IEnumerable<LocalizationOption> GetLocalizationOptions() => new List<LocalizationOption>();
    }
}
