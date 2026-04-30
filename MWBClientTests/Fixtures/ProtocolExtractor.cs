using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace ProtocolExtractor
{
    class Program
    {
        static void Main(string[] args)
        {
            string key = "opencode123!";
            
            // 1. Generate PBKDF2 Key
            string initialIV = ulong.MaxValue.ToString();
            byte[] salt = Encoding.Unicode.GetBytes(initialIV);
            byte[] derivedKey = Rfc2898DeriveBytes.Pbkdf2(key, salt, 50000, HashAlgorithmName.SHA512, 32);
            File.WriteAllBytes("key.bin", derivedKey);

            // 2. Generate Magic Number
            byte[] keyBytes = new byte[32];
            for (int i = 0; i < 32; i++) {
                if (i < key.Length) keyBytes[i] = (byte)key[i];
            }
            using (var sha = SHA512.Create()) {
                byte[] hash = sha.ComputeHash(keyBytes);
                for (int i = 0; i < 50000; i++) hash = sha.ComputeHash(hash);
                uint magic = (uint)((hash[0] << 23) + (hash[1] << 16) + (hash[63] << 8) + hash[2]);
                File.WriteAllBytes("magic.bin", BitConverter.GetBytes(magic));
            }

            // 3. Generate Handshake Packet
            byte[] packet = new byte[64];
            packet[0] = 126; // Handshake
            // Random challenge bytes (16-31)
            for(int i=16; i<32; i++) packet[i] = (byte)i;
            // Name
            byte[] nameBytes = Encoding.ASCII.GetBytes("WIN-REF".PadRight(32, ' '));
            Array.Copy(nameBytes, 0, packet, 32, 32);
            File.WriteAllBytes("handshake.bin", packet);
        }
    }
}
