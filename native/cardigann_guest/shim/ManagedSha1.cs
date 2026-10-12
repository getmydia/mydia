using System;

namespace Mydia.CardigannGuest.Shim
{
    // System.Security.Cryptography is not supported on wasi-wasm, and upstream
    // derives stable custom category ids from a SHA1 of the tracker category
    // (IndexerCapabilitiesCategories). The ids must match Prowlarr's exactly, so
    // this is a plain FIPS 180-4 SHA-1, checked against the BCL in the tests.
    public static class ManagedSha1
    {
        public static byte[] Hash(byte[] data)
        {
            uint h0 = 0x67452301, h1 = 0xEFCDAB89, h2 = 0x98BADCFE, h3 = 0x10325476, h4 = 0xC3D2E1F0;

            var bitLength = (ulong)data.Length * 8;
            var paddedLength = ((data.Length + 8) / 64 + 1) * 64;
            var message = new byte[paddedLength];
            Array.Copy(data, message, data.Length);
            message[data.Length] = 0x80;
            for (var i = 0; i < 8; i++)
            {
                message[paddedLength - 1 - i] = (byte)(bitLength >> (8 * i));
            }

            var w = new uint[80];
            for (var chunk = 0; chunk < paddedLength; chunk += 64)
            {
                for (var i = 0; i < 16; i++)
                {
                    var o = chunk + i * 4;
                    w[i] = ((uint)message[o] << 24) | ((uint)message[o + 1] << 16) | ((uint)message[o + 2] << 8) | message[o + 3];
                }

                for (var i = 16; i < 80; i++)
                {
                    w[i] = Rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
                }

                uint a = h0, b = h1, c = h2, d = h3, e = h4;
                for (var i = 0; i < 80; i++)
                {
                    uint f, k;
                    if (i < 20)
                    {
                        f = (b & c) | (~b & d);
                        k = 0x5A827999;
                    }
                    else if (i < 40)
                    {
                        f = b ^ c ^ d;
                        k = 0x6ED9EBA1;
                    }
                    else if (i < 60)
                    {
                        f = (b & c) | (b & d) | (c & d);
                        k = 0x8F1BBCDC;
                    }
                    else
                    {
                        f = b ^ c ^ d;
                        k = 0xCA62C1D6;
                    }

                    var temp = Rotl(a, 5) + f + e + k + w[i];
                    e = d;
                    d = c;
                    c = Rotl(b, 30);
                    b = a;
                    a = temp;
                }

                h0 += a;
                h1 += b;
                h2 += c;
                h3 += d;
                h4 += e;
            }

            var digest = new byte[20];
            WriteBigEndian(digest, 0, h0);
            WriteBigEndian(digest, 4, h1);
            WriteBigEndian(digest, 8, h2);
            WriteBigEndian(digest, 12, h3);
            WriteBigEndian(digest, 16, h4);
            return digest;
        }

        private static uint Rotl(uint x, int n) => (x << n) | (x >> (32 - n));

        private static void WriteBigEndian(byte[] to, int offset, uint value)
        {
            to[offset] = (byte)(value >> 24);
            to[offset + 1] = (byte)(value >> 16);
            to[offset + 2] = (byte)(value >> 8);
            to[offset + 3] = (byte)value;
        }
    }
}
