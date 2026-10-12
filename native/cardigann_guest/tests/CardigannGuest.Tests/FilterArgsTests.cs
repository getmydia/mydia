using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Mydia.CardigannGuest.Shim;
using Newtonsoft.Json.Linq;
using NzbDrone.Core.IndexerVersions;
using Xunit;

namespace Mydia.CardigannGuest.Tests
{
    // FilterBlock.Args replaces upstream's `dynamic`. These pin its outcomes for
    // each consumer pattern in CardigannBase.ApplyFilters: `(string)Args` (lines
    // 619, 625, 639, 670, 674, 678, 710, 751, 758) and `(string)Args[0]` / `[1]`
    // (645-646, 652-653, 664-665, 736-737). Where upstream's binder threw, so does
    // this; a definition with an odd argument still loads.
    public class FilterArgsTests
    {
        private static string Fixture(string name) => File.ReadAllText(Path.Combine("fixtures", name));
        private static readonly Session Empty = new(new Dictionary<string, string>(), null);

        private const string Yaml = @"
id: elm
name: Elm
type: public
links: [https://elm.invalid/]
caps:
  categorymappings:
    - {id: 1, cat: Movies, desc: Movies}
  modes:
    search: [q]
search:
  paths:
    - path: search
  keywordsfilters:
    - {name: tilde, args: ~}
    - {name: empty, args: }
    - {name: nullword, args: null}
    - {name: quoted, args: ""null""}
    - {name: scalar, args: x}
    - {name: pair, args: [x, y]}
    - {name: withnull, args: [~, y]}
    - {name: nestedlist, args: [[a], y]}
    - {name: nestedmap, args: [{k: v}, y]}
    - {name: mapping, args: {k: v}}
    - {name: none}
";

        private static Dictionary<string, FilterArgs> Args()
        {
            var defs = new SingleDefinitionService(Yaml);
            return defs.GetCachedDefinition(defs.FileKey).Search.Keywordsfilters.ToDictionary(f => f.Name, f => f.Args);
        }

        [Theory]
        [InlineData("tilde")]
        [InlineData("empty")]
        [InlineData("nullword")]
        [InlineData("none")]
        public void Null_forms_are_a_null_args_like_upstream(string name)
        {
            var args = Args()[name];

            Assert.Null(args);
            Assert.Null((string)args);
            Assert.Throws<NullReferenceException>(() => args[0]);
        }

        [Fact]
        public void A_quoted_null_is_the_string()
        {
            Assert.Equal("null", (string)Args()["quoted"]);
        }

        [Fact]
        public void A_scalar_casts_to_string_but_cannot_be_indexed()
        {
            var args = Args()["scalar"];

            Assert.Equal("x", (string)args);
            Assert.Throws<InvalidOperationException>(() => args[0]);
        }

        [Fact]
        public void A_sequence_indexes_but_cannot_be_cast_to_string()
        {
            var args = Args()["pair"];

            Assert.Equal("x", args[0]);
            Assert.Equal("y", args[1]);
            Assert.Throws<InvalidOperationException>(() => (string)args);
            Assert.Throws<IndexOutOfRangeException>(() => args[2]);
        }

        [Fact]
        public void A_null_element_is_a_null_string()
        {
            var args = Args()["withnull"];

            Assert.Null(args[0]);
            Assert.Equal("y", args[1]);
        }

        [Theory]
        [InlineData("nestedlist")]
        [InlineData("nestedmap")]
        public void A_nested_element_loads_and_throws_only_when_read(string name)
        {
            var args = Args()[name];

            Assert.Equal("y", args[1]);
            Assert.Throws<InvalidOperationException>(() => args[0]);
        }

        [Fact]
        public void A_mapping_neither_casts_nor_indexes()
        {
            var args = Args()["mapping"];

            Assert.Throws<InvalidOperationException>(() => (string)args);
            Assert.Throws<InvalidOperationException>(() => args[0]);
        }

        private const string Title = "title:\n      selector: td.name a";

        [Fact]
        public void A_definition_with_a_nested_argument_loads_and_fails_only_where_the_filter_runs()
        {
            var bad = Fixture("lantern-public.yml").Replace(Title,
                Title + "\n      filters:\n        - name: re_replace\n          args: [[a], \"\"]");
            var http = new FakeExchange().On("GET", "/search", _ => FakeExchange.Html(Fixture("lantern-search.html")));
            var q = new QueryInput("search", "harbor", Array.Empty<int>(), null, null, null, null, null, null, null);

            // Loading the definition is fine: capabilities never run the filter.
            Assert.True((bool)JObject.Parse(Runner.Capabilities(bad))["SearchAvailable"]);

            // The filter fails when it runs, so the row (and so the page) is lost,
            // as upstream's RuntimeBinderException lost it.
            Assert.Empty(Runner.Search(bad, new Dictionary<string, string>(), q, Empty, http).Releases);

            // The same definition without the bad argument is untouched.
            Assert.Equal(2, Runner.Search(Fixture("lantern-public.yml"), new Dictionary<string, string>(), q, Empty, http).Releases.Count);
        }
    }
}
