using System;
using System.Collections.Generic;
using System.Linq;
using YamlDotNet.Core;
using YamlDotNet.Core.Events;
using YamlDotNet.Serialization;

namespace Mydia.CardigannGuest.Shim
{
    // Upstream declares FilterBlock.Args `dynamic` and indexes it
    // (`(string)filter.Args[0]`). Under NativeAOT the C# runtime binder cannot
    // index anything: a List<object> fails with "Cannot apply indexing with []
    // to an expression of type 'List<object>'" (trimmed reflection metadata), and
    // a type with its own indexer or an array fails with an
    // ArgumentNullException inside the binder's expression rewriter. Every
    // filter with more than one argument (re_replace, replace, split, ...) then
    // failed on wasm and silently dropped its field or request.
    //
    // This statically typed value replaces `dynamic`, so no call site needs the
    // binder. It supports exactly what upstream does with Args: an explicit
    // conversion to string for a scalar, and an indexer for a sequence.
    public sealed class FilterArgs
    {
        private readonly string[] _items;

        public FilterArgs(params string[] items)
        {
            _items = items;
        }

        public int Count => _items.Length;

        public string this[int index] => _items[index];

        // `(string)filter.Args`: the scalar, or the first element of a sequence.
        public static explicit operator string(FilterArgs args) => args?._items.FirstOrDefault();

        public override string ToString() => string.Join(", ", _items);
    }

    // Reads `args: value` and `args: [a, b]` into FilterArgs.
    public sealed class FilterArgsConverter : IYamlTypeConverter
    {
        public bool Accepts(Type type) => type == typeof(FilterArgs);

        public object ReadYaml(IParser parser, Type type, ObjectDeserializer rootDeserializer)
        {
            if (parser.TryConsume<Scalar>(out var scalar))
            {
                return new FilterArgs(scalar.Value);
            }

            parser.Consume<SequenceStart>();
            var items = new List<string>();
            while (!parser.TryConsume<SequenceEnd>(out _))
            {
                items.Add(parser.Consume<Scalar>().Value);
            }

            return new FilterArgs(items.ToArray());
        }

        public void WriteYaml(IEmitter emitter, object value, Type type, ObjectSerializer serializer)
        {
            throw new NotSupportedException();
        }
    }
}
