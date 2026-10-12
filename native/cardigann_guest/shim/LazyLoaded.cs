using System;
using System.Text.Json.Serialization;

namespace NzbDrone.Core.Datastore
{
    // Same public surface as upstream LazyLoaded<T> minus the database hooks
    // (IDatabase, SqlBuilderExtensions). The guest never lazy loads anything.
    public interface ILazyLoaded : ICloneable
    {
        bool IsLoaded { get; }
        void LazyLoad();
    }

    [JsonConverter(typeof(LazyLoadedConverterFactory))]
    public class LazyLoaded<TChild> : ILazyLoaded
    {
        protected TChild _value;

        public LazyLoaded()
        {
        }

        public LazyLoaded(TChild val)
        {
            _value = val;
            IsLoaded = true;
        }

        public TChild Value
        {
            get
            {
                LazyLoad();
                return _value;
            }
        }

        public bool IsLoaded { get; protected set; }

        public static implicit operator LazyLoaded<TChild>(TChild val)
        {
            return new LazyLoaded<TChild>(val);
        }

        public static implicit operator TChild(LazyLoaded<TChild> lazy)
        {
            return lazy.Value;
        }

        public virtual void LazyLoad()
        {
        }

        public object Clone()
        {
            return MemberwiseClone();
        }
    }
}
