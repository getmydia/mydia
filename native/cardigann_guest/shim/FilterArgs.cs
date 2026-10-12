using System;
using System.Collections.Generic;
using YamlDotNet.Core;
using YamlDotNet.Core.Events;
using YamlDotNet.Serialization;

namespace Mydia.CardigannGuest.Shim
{
    // Upstream declares FilterBlock.Args `dynamic` and consumes it two ways:
    // `(string)filter.Args` and `(string)filter.Args[n]`. Under NativeAOT the C#
    // runtime binder cannot bind any dynamic operation: a List<object> fails with
    // "Cannot apply indexing with [] to an expression of type 'List<object>'"
    // (trimmed reflection metadata), and a type with its own indexer or an array
    // fails with an ArgumentNullException inside the binder's expression
    // rewriter. Every filter argument read then failed on wasm and ParseFields
    // swallowed it, silently dropping fields, dates and whole requests.
    //
    // This statically typed value replaces `dynamic` and reproduces upstream's
    // outcome for every shape YamlDotNet could put there (a null Args is a null
    // reference, as upstream):
    //
    //   Args shape        (string)Args            Args[n]
    //   scalar            the string              throws (a char is not a string)
    //   sequence          throws                  element n; throws for a nested
    //                                             sequence or mapping, or out of range
    //   mapping           throws                  throws (no such key)
    //   null (~, empty)   null                    NullReferenceException
    //
    // "Throws" is where upstream's binder threw RuntimeBinderException. A
    // definition with an odd argument still loads and fails only when its filter
    // runs, like upstream.
    public sealed class FilterArgs
    {
        private enum Shape
        {
            Scalar,
            Sequence,
            Mapping
        }

        // Stands for a nested sequence or mapping inside a sequence.
        private static readonly object Nested = new object();

        private readonly Shape _shape;
        private readonly string _scalar;
        private readonly object[] _items;

        private FilterArgs(Shape shape, string scalar, object[] items)
        {
            _shape = shape;
            _scalar = scalar;
            _items = items;
        }

        public static FilterArgs OfScalar(string value) => new FilterArgs(Shape.Scalar, value, null);

        public static FilterArgs OfSequence(object[] items) => new FilterArgs(Shape.Sequence, null, items);

        public static FilterArgs OfMapping() => new FilterArgs(Shape.Mapping, null, null);

        public static object NestedItem => Nested;

        public string this[int index]
        {
            get
            {
                if (_shape != Shape.Sequence)
                {
                    throw new InvalidOperationException(_shape == Shape.Scalar
                        ? "Cannot index a scalar filter argument as a list"
                        : "Cannot index a mapping filter argument by position");
                }

                var item = _items[index];
                if (ReferenceEquals(item, Nested))
                {
                    throw new InvalidOperationException("Filter argument " + index + " is a nested list or mapping, not a string");
                }

                return (string)item;
            }
        }

        // `(string)filter.Args`.
        public static explicit operator string(FilterArgs args)
        {
            if (args == null)
            {
                return null;
            }

            if (args._shape != Shape.Scalar)
            {
                throw new InvalidOperationException("Cannot convert a " + args._shape.ToString().ToLowerInvariant() + " filter argument to a string");
            }

            return args._scalar;
        }

        public override string ToString() => _shape == Shape.Scalar ? _scalar : _shape.ToString();
    }

    // Reads `args:` into FilterArgs, or null where upstream's object would be null.
    public sealed class FilterArgsConverter : IYamlTypeConverter
    {
        public bool Accepts(Type type) => type == typeof(FilterArgs);

        public object ReadYaml(IParser parser, Type type, ObjectDeserializer rootDeserializer)
        {
            if (parser.Accept<Scalar>(out _))
            {
                var scalar = parser.Consume<Scalar>();
                return IsNull(scalar) ? null : FilterArgs.OfScalar(scalar.Value);
            }

            if (parser.Accept<SequenceStart>(out _))
            {
                parser.Consume<SequenceStart>();
                var items = new List<object>();
                while (!parser.TryConsume<SequenceEnd>(out _))
                {
                    if (parser.Accept<Scalar>(out _))
                    {
                        var item = parser.Consume<Scalar>();
                        items.Add(IsNull(item) ? null : item.Value);
                    }
                    else
                    {
                        parser.SkipThisAndNestedEvents();
                        items.Add(FilterArgs.NestedItem);
                    }
                }

                return FilterArgs.OfSequence(items.ToArray());
            }

            parser.SkipThisAndNestedEvents();
            return FilterArgs.OfMapping();
        }

        public void WriteYaml(IEmitter emitter, object value, Type type, ObjectSerializer serializer)
        {
            throw new NotSupportedException();
        }

        // YamlDotNet's own rule for an untyped value: an unquoted empty, "~",
        // "null", "Null" or "NULL" scalar is null.
        private static bool IsNull(Scalar scalar) =>
            scalar.Style == ScalarStyle.Plain
            && scalar.Tag.IsEmpty
            && (scalar.Value == string.Empty || scalar.Value == "~" || scalar.Value == "null"
                || scalar.Value == "Null" || scalar.Value == "NULL");
    }
}
