using System.Buffers.Binary;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Windows.Forms;

namespace JuanchoBuilder;

internal static class Program
{
    [STAThread]
    static void Main()
    {
        ApplicationConfiguration.Initialize();
        Application.Run(new MainForm());
    }
}

internal sealed class MainForm : Form
{
    readonly TextBox projectName = new();
    readonly TextBox bundleId = new();
    readonly TextBox basePath = new();
    readonly TextBox sourcePath = new();
    readonly TextBox password = new();
    readonly Label status = new();
    readonly ProgressBar progress = new();

    public MainForm()
    {
        Text = "Juancho Package Builder";
        Width = 760;
        Height = 600;
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        BackColor = Color.White;

        var root = new TableLayoutPanel {
            Dock = DockStyle.Fill,
            Padding = new Padding(18),
            ColumnCount = 2,
            RowCount = 8
        };
        root.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 150));
        root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));

        AddRow(root, 0, "Project name", projectName, "SkinPack");
        AddRow(root, 1, "Target Bundle ID", bundleId, "com.example.game");
        AddRow(root, 2, "Base path", basePath, "assets");
        AddRow(root, 3, "Source folder", sourcePath, "folder with replacement files");
        AddRow(root, 4, "Password", password, "optional");
        password.UseSystemPasswordChar = true;

        var browse = new Button { Text = "Browse...", AutoSize = true };
        browse.Click += (_, _) => BrowseSource();
        if (root.GetControlFromPosition(1, 3) is Panel sourcePanel)
            sourcePanel.Controls.Add(browse);

        var actions = new FlowLayoutPanel {
            Dock = DockStyle.Fill,
            AutoSize = true
        };

        var create = new Button {
            Text = "Create .juancho",
            AutoSize = true,
            Padding = new Padding(12, 7, 12, 7)
        };
        create.Click += async (_, _) => await CreateAsync();

        var extract = new Button {
            Text = "Extract .juancho",
            AutoSize = true,
            Padding = new Padding(12, 7, 12, 7)
        };
        extract.Click += async (_, _) => await ExtractAsync();

        actions.Controls.Add(create);
        actions.Controls.Add(extract);

        root.Controls.Add(new Label(), 0, 5);
        root.Controls.Add(actions, 1, 5);

        progress.Dock = DockStyle.Fill;
        progress.Visible = false;
        root.Controls.Add(new Label(), 0, 6);
        root.Controls.Add(progress, 1, 6);

        status.Text = "Ready";
        status.Dock = DockStyle.Fill;
        status.TextAlign = ContentAlignment.MiddleLeft;
        root.Controls.Add(new Label(), 0, 7);
        root.Controls.Add(status, 1, 7);

        projectName.Text = "SkinPack";
        bundleId.Text = "com.mobile.legends";
        basePath.Text = "assets";

        var help = new Label {
            Dock = DockStyle.Bottom,
            Height = 90,
            Padding = new Padding(18, 2, 18, 12),
            Text =
                "The source folder mirrors the destination under Base path. " +
                "A password enables AES-GCM encryption using PBKDF2-HMAC-SHA256. " +
                "The generated file is a JUANCHO1 package and is compatible with the iOS Juancho patcher."
        };

        Controls.Add(help);
        Controls.Add(root);
    }

    static void AddRow(TableLayoutPanel root, int row, string labelText, TextBox box, string placeholder)
    {
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 58));

        var label = new Label {
            Text = labelText,
            Dock = DockStyle.Fill,
            TextAlign = ContentAlignment.MiddleLeft
        };

        var panel = new Panel { Dock = DockStyle.Fill };
        box.Dock = DockStyle.Fill;
        box.PlaceholderText = placeholder;
        panel.Controls.Add(box);

        root.Controls.Add(label, 0, row);
        root.Controls.Add(panel, 1, row);
    }

    void BrowseSource()
    {
        using var dialog = new FolderBrowserDialog {
            Description = "Select the replacement source folder"
        };

        if (dialog.ShowDialog(this) == DialogResult.OK)
        {
            sourcePath.Text = dialog.SelectedPath;
            if (projectName.Text == "SkinPack")
                projectName.Text = new DirectoryInfo(dialog.SelectedPath).Name;
        }
    }

    async Task CreateAsync()
    {
        try
        {
            ValidateInputs();

            var name = projectName.Text.Trim();
            var targetBundle = bundleId.Text.Trim();
            var basePathNormalized = NormalizeRelative(basePath.Text);
            var source = Path.GetFullPath(sourcePath.Text.Trim());

            status.Text = "Scanning source...";
            progress.Visible = true;
            progress.Style = ProgressBarStyle.Marquee;
            await Task.Yield();

            var files = Directory
                .EnumerateFiles(source, "*", SearchOption.AllDirectories)
                .Select(p => new SourceFile(
                    p,
                    Path.GetRelativePath(source, p).Replace('\\', '/')))
                .OrderBy(x => x.RelativePath, StringComparer.Ordinal)
                .ToList();

            if (files.Count == 0)
                throw new InvalidOperationException("No files were found in the source folder.");

            progress.Style = ProgressBarStyle.Continuous;
            progress.Minimum = 0;
            progress.Maximum = files.Count;
            progress.Value = 0;

            var rules = new List<RuleRecord>(files.Count);
            var fileData = new List<(string Path, byte[] Data)>(files.Count);

            foreach (var file in files)
            {
                var data = await File.ReadAllBytesAsync(file.FullPath);
                fileData.Add((file.RelativePath, data));

                rules.Add(new RuleRecord {
                    Operation = "replace",
                    ContainerKind = "data",
                    BundleID = targetBundle,
                    RelativePath = string.IsNullOrEmpty(base)
                        ? file.RelativePath
                        : base + "/" + file.RelativePath,
                    ReplacementFilename = Path.GetFileName(file.FullPath),
                    Size = data.LongLength,
                    SHA256 = Sha256(data),
                    CanRemove = true
                });

                progress.Value++;
            }

            var manifest = new ManifestRecord {
                FormatVersion = 1,
                ProjectName = name,
                BundleIdentifiers = new[] { targetBundle },
                Directories = rules
                    .Select(r => Path.GetDirectoryName(r.RelativePath)?.Replace('\\', '/') ?? "")
                    .Where(p => !string.IsNullOrWhiteSpace(p))
                    .Distinct(StringComparer.Ordinal)
                    .OrderBy(p => p, StringComparer.Ordinal)
                    .ToArray(),
                Rules = rules
            };

            var manifestJson = JsonSerializer.SerializeToUtf8Bytes(manifest, JsonOptions.Instance);

            using var plainStream = new MemoryStream();
            WriteUInt32(plainStream, checked((uint)manifestJson.Length));
            plainStream.Write(manifestJson);

            using var archive = new MemoryStream();
            archive.Write(Encoding.ASCII.GetBytes("JNPAYL1"));
            WriteUInt32(archive, checked((uint)fileData.Count));

            foreach (var entry in fileData)
            {
                var pathBytes = Encoding.UTF8.GetBytes(entry.Path);
                WriteUInt32(archive, checked((uint)pathBytes.Length));
                WriteUInt64(archive, checked((ulong)entry.Data.LongLength));
                archive.Write(pathBytes);
                archive.Write(entry.Data);
            }

            plainStream.Write(archive.ToArray());
            var plain = plainStream.ToArray();
            var compressed = CompressZlib(plain);
            var payloadHash = Sha256(compressed);

            var protectedPackage = !string.IsNullOrEmpty(password.Text);
            var finalPayload = compressed;
            string? kdf = null;
            int? iterations = null;
            string? saltB64 = null;
            string? nonceB64 = null;
            string? aad = null;

            if (protectedPackage)
            {
                const int pbkdf2Iterations = 120_000;
                var salt = RandomNumberGenerator.GetBytes(16);
                var nonce = RandomNumberGenerator.GetBytes(12);
                var aadBytes = Encoding.UTF8.GetBytes($"JUANCHO1/v1/{name}");
                var key = Rfc2898DeriveBytes.Pbkdf2(
                    password.Text,
                    salt,
                    pbkdf2Iterations,
                    HashAlgorithmName.SHA256,
                    32);

                var ciphertext = new byte[compressed.Length];
                var tag = new byte[16];

                using var aes = new AesGcm(key, 16);
                aes.Encrypt(nonce, compressed, ciphertext, tag, aadBytes);

                finalPayload = new byte[ciphertext.Length + tag.Length];
                Buffer.BlockCopy(ciphertext, 0, finalPayload, 0, ciphertext.Length);
                Buffer.BlockCopy(tag, 0, finalPayload, ciphertext.Length, tag.Length);

                kdf = "PBKDF2-HMAC-SHA256";
                iterations = pbkdf2Iterations;
                saltB64 = Convert.ToBase64String(salt);
                nonceB64 = Convert.ToBase64String(nonce);
                aad = Encoding.UTF8.GetString(aadBytes);
            }

            var header = new HeaderRecord {
                FormatVersion = 1,
                ProjectName = name,
                TargetBundleID = targetBundle,
                BasePath = basePathNormalized,
                PasswordProtected = protectedPackage,
                Compression = "zlib",
                PayloadEncoding = "juanchopayload-v1",
                PayloadUncompressedSize = plain.LongLength,
                PayloadCompressedSize = compressed.LongLength,
                PayloadSHA256 = payloadHash,
                CreatedAt = DateTimeOffset.UtcNow.ToString("O"),
                Kdf = kdf,
                KdfIterations = iterations,
                Salt = saltB64,
                Nonce = nonceB64,
                Aad = aad
            };

            var headerJson = JsonSerializer.SerializeToUtf8Bytes(header, JsonOptions.Instance);
            if (headerJson.Length > 1_000_000)
                throw new InvalidOperationException("Header is too large.");

            using var output = new MemoryStream();
            output.Write(Encoding.ASCII.GetBytes("JUANCHO1"));
            output.WriteByte(1);
            output.WriteByte(protectedPackage ? (byte)1 : (byte)0);
            WriteUInt32(output, checked((uint)headerJson.Length));
            output.Write(headerJson);
            output.Write(finalPayload);

            var desktop = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
            var outputPath = Path.Combine(desktop, name + ".juancho");

            if (File.Exists(outputPath))
            {
                var answer = MessageBox.Show(
                    this,
                    $"{name}.juancho already exists. Replace it?",
                    "Juancho",
                    MessageBoxButtons.YesNo,
                    MessageBoxIcon.Question);

                if (answer != DialogResult.Yes)
                    return;
            }

            await File.WriteAllBytesAsync(outputPath, output.ToArray());

            // Validate the file we just wrote using the same codec logic used by extraction.
            _ = PackageCodec.Decode(await File.ReadAllBytesAsync(outputPath), protectedPackage ? password.Text : null);

            status.Text = $"Created {outputPath}";
            MessageBox.Show(
                this,
                $"Juancho package created and verified.\n\n{outputPath}",
                "Juancho",
                MessageBoxButtons.OK,
                MessageBoxIcon.Information);
        }
        catch (Exception ex)
        {
            status.Text = "Create failed";
            MessageBox.Show(
                this,
                ex.Message,
                "Juancho",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
        }
        finally
        {
            progress.Visible = false;
        }
    }

    async Task ExtractAsync()
    {
        try
        {
            using var dialog = new OpenFileDialog {
                Title = "Open .juancho package",
                Filter = "Juancho packages (*.juancho)|*.juancho|All files (*.*)|*.*",
                CheckFileExists = true,
                Multiselect = false
            };

            if (dialog.ShowDialog(this) != DialogResult.OK)
                return;

            var packagePath = dialog.FileName;
            var data = await File.ReadAllBytesAsync(packagePath);
            var header = PackageCodec.ReadHeader(data);

            string? suppliedPassword = null;
            if (header.PasswordProtected)
            {
                using var passwordDialog = new PasswordForm();
                if (passwordDialog.ShowDialog(this) != DialogResult.OK)
                    return;

                suppliedPassword = passwordDialog.Password;
            }

            var decoded = PackageCodec.Decode(data, suppliedPassword);
            var desktop = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
            var output = Path.Combine(desktop, Path.GetFileNameWithoutExtension(packagePath) + "_extracted");
            Directory.CreateDirectory(output);

            var root = Path.GetFullPath(output) + Path.DirectorySeparatorChar;

            foreach (var file in decoded.Files)
            {
                var relative = file.Path.Replace('/', Path.DirectorySeparatorChar);
                var destination = Path.GetFullPath(Path.Combine(output, relative));

                if (!destination.StartsWith(root, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException("Unsafe extraction path.");

                Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
                await File.WriteAllBytesAsync(destination, file.Data);
            }

            status.Text = $"Extracted to {output}";
            MessageBox.Show(
                this,
                $"Extraction complete.\n\n{output}",
                "Juancho",
                MessageBoxButtons.OK,
                MessageBoxIcon.Information);
        }
        catch (Exception ex)
        {
            status.Text = "Extract failed";
            MessageBox.Show(
                this,
                ex.Message,
                "Juancho",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
        }
    }

    void ValidateInputs()
    {
        if (string.IsNullOrWhiteSpace(projectName.Text))
            throw new InvalidOperationException("Project name is required.");

        if (string.IsNullOrWhiteSpace(bundleId.Text))
            throw new InvalidOperationException("Target Bundle ID is required.");

        if (bundleId.Text.Any(char.IsWhiteSpace))
            throw new InvalidOperationException("Target Bundle ID cannot contain spaces.");

        if (string.IsNullOrWhiteSpace(sourcePath.Text))
            throw new InvalidOperationException("Source folder is required.");

        if (!Directory.Exists(sourcePath.Text.Trim()))
            throw new InvalidOperationException("Source folder was not found.");

        _ = NormalizeRelative(basePath.Text);
    }

    static string NormalizeRelative(string value)
    {
        var normalized = value.Trim().Replace('\\', '/').Trim('/');

        if (normalized.Contains("..", StringComparison.Ordinal) ||
            normalized.Contains(':') ||
            normalized.StartsWith('/'))
            throw new InvalidOperationException("Base path is unsafe.");

        return normalized;
    }

    static byte[] CompressZlib(byte[] data)
    {
        using var output = new MemoryStream();
        using (var zlib = new ZLibStream(output, CompressionLevel.Optimal, true))
        {
            zlib.Write(data);
        }
        return output.ToArray();
    }

    static byte[] DecompressZlib(byte[] data, long expectedSize)
    {
        using var input = new MemoryStream(data);
        using var zlib = new ZLibStream(input, CompressionMode.Decompress);
        using var output = new MemoryStream();
        zlib.CopyTo(output);

        if (output.Length != expectedSize)
            throw new InvalidDataException("Decompressed size does not match package header.");

        return output.ToArray();
    }

    static string Sha256(byte[] data) =>
        Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();

    static void WriteUInt32(Stream stream, uint value)
    {
        Span<byte> buffer = stackalloc byte[4];
        BinaryPrimitives.WriteUInt32LittleEndian(buffer, value);
        stream.Write(buffer);
    }

    static void WriteUInt64(Stream stream, ulong value)
    {
        Span<byte> buffer = stackalloc byte[8];
        BinaryPrimitives.WriteUInt64LittleEndian(buffer, value);
        stream.Write(buffer);
    }
}

internal sealed record SourceFile(string FullPath, string RelativePath);

internal sealed class PasswordForm : Form
{
    readonly TextBox password = new();

    public string Password => password.Text;

    public PasswordForm()
    {
        Text = "Juancho Password";
        Width = 430;
        Height = 160;
        StartPosition = FormStartPosition.CenterParent;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;

        var layout = new TableLayoutPanel {
            Dock = DockStyle.Fill,
            Padding = new Padding(12),
            ColumnCount = 2,
            RowCount = 2
        };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 90));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));

        layout.Controls.Add(new Label {
            Text = "Password",
            Dock = DockStyle.Fill,
            TextAlign = ContentAlignment.MiddleLeft
        }, 0, 0);

        password.Dock = DockStyle.Fill;
        password.UseSystemPasswordChar = true;
        layout.Controls.Add(password, 1, 0);

        var unlock = new Button {
            Text = "Unlock",
            AutoSize = true,
            DialogResult = DialogResult.OK
        };
        var cancel = new Button {
            Text = "Cancel",
            AutoSize = true,
            DialogResult = DialogResult.Cancel
        };

        var buttons = new FlowLayoutPanel {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.RightToLeft
        };
        buttons.Controls.Add(cancel);
        buttons.Controls.Add(unlock);

        layout.Controls.Add(new Label(), 0, 1);
        layout.Controls.Add(buttons, 1, 1);

        AcceptButton = unlock;
        CancelButton = cancel;
        Controls.Add(layout);
    }
}

internal static class JsonOptions
{
    public static readonly JsonSerializerOptions Instance = new() {
        PropertyNamingPolicy = null,
        WriteIndented = false
    };
}

internal sealed class HeaderRecord
{
    [JsonPropertyName("formatVersion")] public int FormatVersion { get; set; }
    [JsonPropertyName("projectName")] public string ProjectName { get; set; } = "";
    [JsonPropertyName("targetBundleID")] public string TargetBundleID { get; set; } = "";
    [JsonPropertyName("basePath")] public string BasePath { get; set; } = "";
    [JsonPropertyName("passwordProtected")] public bool PasswordProtected { get; set; }
    [JsonPropertyName("compression")] public string Compression { get; set; } = "";
    [JsonPropertyName("payloadEncoding")] public string PayloadEncoding { get; set; } = "";
    [JsonPropertyName("payloadUncompressedSize")] public long PayloadUncompressedSize { get; set; }
    [JsonPropertyName("payloadCompressedSize")] public long PayloadCompressedSize { get; set; }
    [JsonPropertyName("payloadSHA256")] public string PayloadSHA256 { get; set; } = "";
    [JsonPropertyName("createdAt")] public string CreatedAt { get; set; } = "";
    [JsonPropertyName("kdf")] public string? Kdf { get; set; }
    [JsonPropertyName("kdfIterations")] public int? KdfIterations { get; set; }
    [JsonPropertyName("salt")] public string? Salt { get; set; }
    [JsonPropertyName("nonce")] public string? Nonce { get; set; }
    [JsonPropertyName("aad")] public string? Aad { get; set; }
}

internal sealed class ManifestRecord
{
    [JsonPropertyName("formatVersion")] public int FormatVersion { get; set; }
    [JsonPropertyName("projectName")] public string ProjectName { get; set; } = "";
    [JsonPropertyName("bundleIdentifiers")] public string[] BundleIdentifiers { get; set; } = Array.Empty<string>();
    [JsonPropertyName("directories")] public string[] Directories { get; set; } = Array.Empty<string>();
    [JsonPropertyName("rules")] public List<RuleRecord> Rules { get; set; } = new();
}

internal sealed class RuleRecord
{
    [JsonPropertyName("operation")] public string Operation { get; set; } = "replace";
    [JsonPropertyName("containerKind")] public string ContainerKind { get; set; } = "data";
    [JsonPropertyName("bundleID")] public string BundleID { get; set; } = "";
    [JsonPropertyName("relativePath")] public string RelativePath { get; set; } = "";
    [JsonPropertyName("replacementFilename")] public string ReplacementFilename { get; set; } = "";
    [JsonPropertyName("size")] public long Size { get; set; }
    [JsonPropertyName("sha256")] public string SHA256 { get; set; } = "";
    [JsonPropertyName("canRemove")] public bool CanRemove { get; set; }
}

internal sealed record DecodedFile(string Path, byte[] Data);
internal sealed record DecodedPackage(HeaderRecord Header, ManifestRecord Manifest, List<DecodedFile> Files);

internal static class PackageCodec
{
    static readonly byte[] Magic = Encoding.ASCII.GetBytes("JUANCHO1");
    static readonly byte[] ArchiveMagic = Encoding.ASCII.GetBytes("JNPAYL1");

    public static HeaderRecord ReadHeader(byte[] data)
    {
        if (data.Length <= 14 ||
            !data.AsSpan(0, 8).SequenceEqual(Magic))
            throw new InvalidDataException("Not a JUANCHO package.");

        if (data[8] != 1)
            throw new InvalidDataException("Unsupported JUANCHO package version.");

        var headerLength = checked((int)BinaryPrimitives.ReadUInt32LittleEndian(data.AsSpan(10, 4)));
        var start = 14;
        var end = checked(start + headerLength);

        if (headerLength <= 0 || headerLength > 1_000_000 || end > data.Length)
            throw new InvalidDataException("Malformed JUANCHO header.");

        return JsonSerializer.Deserialize<HeaderRecord>(
            data.AsSpan(start, headerLength),
            JsonOptions.Instance)
            ?? throw new InvalidDataException("Malformed JUANCHO header JSON.");
    }

    public static DecodedPackage Decode(byte[] data, string? password)
    {
        var header = ReadHeader(data);
        var encryptedFlag = (data[9] & 1) != 0;

        if (encryptedFlag != header.PasswordProtected)
            throw new InvalidDataException("Package encryption flag does not match header.");

        var headerLength = checked((int)BinaryPrimitives.ReadUInt32LittleEndian(data.AsSpan(10, 4)));
        var payload = data.AsSpan(14 + headerLength).ToArray();

        if (header.PasswordProtected)
        {
            if (string.IsNullOrEmpty(password))
                throw new InvalidDataException("This package requires a password.");

            if (header.KdfIterations is null ||
                header.KdfIterations.Value < 1 ||
                string.IsNullOrWhiteSpace(header.Salt) ||
                string.IsNullOrWhiteSpace(header.Nonce))
                throw new InvalidDataException("Encrypted package is missing crypto metadata.");

            var salt = Convert.FromBase64String(header.Salt);
            var nonce = Convert.FromBase64String(header.Nonce);
            var aad = Encoding.UTF8.GetBytes($"JUANCHO1/v1/{header.ProjectName}");
            var key = Rfc2898DeriveBytes.Pbkdf2(
                password,
                salt,
                header.KdfIterations.Value,
                HashAlgorithmName.SHA256,
                32);

            if (payload.Length < 16)
                throw new InvalidDataException("Encrypted payload is too small.");

            var cipherLength = payload.Length - 16;
            var ciphertext = payload.AsSpan(0, cipherLength);
            var tag = payload.AsSpan(cipherLength, 16);
            var decrypted = new byte[cipherLength];

            using var aes = new AesGcm(key, 16);
            aes.Decrypt(nonce, ciphertext, tag, decrypted, aad);
            payload = decrypted;
        }

        if (!string.Equals(
                Sha256(payload),
                header.PayloadSHA256,
                StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Payload SHA-256 verification failed.");

        if (header.PayloadUncompressedSize <= 0)
            throw new InvalidDataException("Invalid uncompressed payload size.");

        var plain = DecompressZlib(payload, header.PayloadUncompressedSize);

        if (plain.Length < 4)
            throw new InvalidDataException("Malformed package payload.");

        var manifestLength = checked((int)BinaryPrimitives.ReadUInt32LittleEndian(plain.AsSpan(0, 4)));

        if (manifestLength <= 0 || 4 + manifestLength > plain.Length)
            throw new InvalidDataException("Malformed manifest.");

        var manifest = JsonSerializer.Deserialize<ManifestRecord>(
            plain.AsSpan(4, manifestLength),
            JsonOptions.Instance)
            ?? throw new InvalidDataException("Malformed manifest.");

        ValidateManifest(manifest, header);

        var archive = plain.AsSpan(4 + manifestLength).ToArray();
        var files = DecodeArchive(archive);

        if (files.Count != manifest.Rules.Count)
            throw new InvalidDataException("Archive/manifest file count mismatch.");

        foreach (var file in files)
        {
            var rule = FindRule(file.Path, header.BasePath, manifest.Rules)
                ?? throw new InvalidDataException($"Archive entry is not in the manifest: {file.Path}");

            if (file.Data.LongLength != rule.Size ||
                !string.Equals(Sha256(file.Data), rule.SHA256, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException($"Hash verification failed: {rule.RelativePath}");
        }

        return new DecodedPackage(header, manifest, files);
    }

    static void ValidateManifest(ManifestRecord manifest, HeaderRecord header)
    {
        if (manifest.FormatVersion != 1 ||
            string.IsNullOrWhiteSpace(manifest.ProjectName) ||
            !string.Equals(manifest.ProjectName, header.ProjectName, StringComparison.Ordinal) ||
            manifest.BundleIdentifiers.Length == 0 ||
            !manifest.BundleIdentifiers.Contains(header.TargetBundleID, StringComparer.Ordinal))
            throw new InvalidDataException("Manifest/header metadata mismatch.");

        var seen = new HashSet<string>(StringComparer.Ordinal);

        foreach (var rule in manifest.Rules)
        {
            var normalized = rule.RelativePath.Replace('\\', '/').Trim('/');

            if (rule.Operation != "replace" ||
                rule.BundleID != header.TargetBundleID ||
                string.IsNullOrWhiteSpace(normalized) ||
                normalized.StartsWith('/') ||
                normalized.Split('/').Contains("..") ||
                normalized.Contains(':'))
                throw new InvalidDataException("Manifest contains an unsafe rule.");

            if (!seen.Add(normalized))
                throw new InvalidDataException("Manifest contains a duplicate destination.");
        }
    }

    static RuleRecord? FindRule(string archivePath, string basePath, List<RuleRecord> rules)
    {
        var archive = archivePath.Replace('\\', '/').Trim('/');
        var base = basePath.Replace('\\', '/').Trim('/');
        var prefix = string.IsNullOrEmpty(basePathNormalized) ? "" : basePathNormalized + "/";

        return rules.FirstOrDefault(rule =>
        {
            var destination = rule.RelativePath.Replace('\\', '/').Trim('/');
            var candidate = destination.StartsWith(prefix, StringComparison.Ordinal)
                ? destination[prefix.Length..]
                : destination;

            return string.Equals(candidate, archive, StringComparison.Ordinal);
        });
    }

    static List<DecodedFile> DecodeArchive(byte[] data)
    {
        if (data.Length < 11 || !data.AsSpan(0, 7).SequenceEqual(ArchiveMagic))
            throw new InvalidDataException("Malformed Juancho archive payload.");

        var cursor = 7;
        var count = checked((int)BinaryPrimitives.ReadUInt32LittleEndian(data.AsSpan(cursor, 4)));
        cursor += 4;

        if (count < 1 || count > 100_000)
            throw new InvalidDataException("Invalid archive file count.");

        var result = new List<DecodedFile>(count);
        var seen = new HashSet<string>(StringComparer.Ordinal);

        for (var i = 0; i < count; i++)
        {
            if (cursor + 12 > data.Length)
                throw new InvalidDataException("Malformed archive entry.");

            var pathLength = checked((int)BinaryPrimitives.ReadUInt32LittleEndian(data.AsSpan(cursor, 4)));
            cursor += 4;
            var dataLength64 = BinaryPrimitives.ReadUInt64LittleEndian(data.AsSpan(cursor, 8));
            cursor += 8;

            if (pathLength <= 0 || dataLength64 > int.MaxValue ||
                pathLength > data.Length - cursor ||
                dataLength64 > (ulong)(data.Length - cursor - pathLength))
                throw new InvalidDataException("Malformed archive entry length.");

            var path = Encoding.UTF8.GetString(data, cursor, pathLength)
                .Replace('\\', '/')
                .Trim('/');
            cursor += pathLength;

            if (string.IsNullOrEmpty(path) ||
                path.StartsWith('/') ||
                path.Split('/').Contains("..") ||
                path.Contains(':') ||
                !seen.Add(path))
                throw new InvalidDataException("Unsafe archive path.");

            var length = checked((int)dataLength64);
            var bytes = data.AsSpan(cursor, length).ToArray();
            cursor += length;

            result.Add(new DecodedFile(path, bytes));
        }

        if (cursor != data.Length)
            throw new InvalidDataException("Trailing bytes found in archive payload.");

        return result;
    }

    static byte[] DecompressZlib(byte[] data, long expectedSize)
    {
        using var input = new MemoryStream(data);
        using var zlib = new ZLibStream(input, CompressionMode.Decompress);
        using var output = new MemoryStream();
        zlib.CopyTo(output);

        if (output.Length != expectedSize)
            throw new InvalidDataException("Decompressed size does not match header.");

        return output.ToArray();
    }

    static string Sha256(byte[] data) =>
        Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();
}
