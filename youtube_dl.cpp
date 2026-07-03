#include "youtube_dl.h"

#include <QCryptographicHash>
#include <QDirIterator>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QSslError>

#if defined(Q_OS_MAC)
#include <sys/xattr.h>
#endif

YoutubeDl::YoutubeDl()
{

}

QString YoutubeDl::path = QString();

QString YoutubeDl::expectedReleaseAssetName() {
#if defined(Q_OS_WIN)
    return "yt-dlp_win.zip";   // onedir bundle — fast cold start
#elif defined(Q_OS_MAC)
    return "yt-dlp_macos.zip"; // onedir bundle — fast cold start
#else
    return "yt-dlp";           // Linux: still the .py script
#endif
}

QString YoutubeDl::bundledBinaryName() {
    // yt-dlp's PyInstaller bundles name the binary after the asset:
    // yt-dlp_macos.zip → yt-dlp_macos, yt-dlp_win.zip → yt-dlp.exe (the
    // x64 variant — _x86 / _arm64 use different filenames but we don't
    // download those assets). Linux just runs the .py script.
#if defined(Q_OS_WIN)
    return "yt-dlp.exe";
#elif defined(Q_OS_MAC)
    return "yt-dlp_macos";
#else
    return "yt-dlp";
#endif
}

QString YoutubeDl::installDir() {
    QString base = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
#if defined(Q_OS_WIN) || defined(Q_OS_MAC)
    return base + "/yt-dlp";
#else
    return base;
#endif
}

QString YoutubeDl::find(bool force) {
    if (!force && !path.isEmpty()) return path;

    // Prefer the downloaded copy. On macOS/Windows that's the extracted
    // onedir bundle; on Linux it's the .py script.
    QString localPath = installDir() + "/" + bundledBinaryName();
    if (QFile::exists(localPath)) {
        QProcess* process = instance(localPath, QStringList() << "--version");
        process->start();
        process->waitForFinished();
        if (process->state() != QProcess::NotRunning) process->kill();
        bool ok = process->exitStatus() == QProcess::NormalExit && process->exitCode() == 0;
        process->deleteLater();
        if (ok) {
            path = localPath;
            return path;
        }
    }

    // Try system-wide yt-dlp installation
    QString globalPath = QStandardPaths::findExecutable("yt-dlp");
    if (!globalPath.isEmpty()) {
        QProcess* process = instance(globalPath, QStringList() << "--version");
        process->start();
        process->waitForFinished();
        if (process->state() != QProcess::NotRunning) process->kill();
        bool ok = process->exitStatus() == QProcess::NormalExit && process->exitCode() == 0;
        process->deleteLater();
        if (ok) {
            path = globalPath;
            return path;
        }
    }

    return "";
}

QProcess* YoutubeDl::instance(QStringList arguments) {
    return instance(find(), arguments);
}

QProcess* YoutubeDl::instance(QString path, QStringList arguments) {
    QProcess *process = new QProcess();

    QString execPath = QCoreApplication::applicationDirPath();
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();

    // Put execPath (bundled ffmpeg / deno) on PATH for the spawned yt-dlp;
    // on macOS also add the usual Homebrew / system bin dirs so a JS
    // runtime (deno / node) is found when the YouTube extractor needs it.
    #if defined(Q_OS_WIN)
        env.insert("PATH", QDir::toNativeSeparators(execPath) + ";" + env.value("PATH"));
    #elif defined(Q_OS_MAC)
        QStringList pathParts;
        pathParts << execPath
                  << "/opt/homebrew/bin"
                  << "/opt/homebrew/sbin"
                  << "/usr/local/bin"
                  << "/usr/local/sbin"
                  << env.value("PATH");
        env.insert("PATH", pathParts.join(":"));
    #else
        env.insert("PATH", execPath + ":" + env.value("PATH"));
    #endif

    // macOS/Windows spawn the self-contained PyInstaller bundle directly;
    // Linux still runs the .py script through the system Python.
    #if defined(Q_OS_WIN) || defined(Q_OS_MAC)
        process->setProgram(path);
    #else
        process->setProgram(QStandardPaths::findExecutable("python3"));
        arguments.prepend(path);
    #endif

    QSettings settings;
    QStringList proxyArguments;
    if (settings.value("UseProxy", false).toBool()) {
        QUrl proxyUrl;

        proxyUrl.setHost(settings.value("ProxyHost", "").toString());
        proxyUrl.setPort(settings.value("ProxyPort", "").toInt());

        if (settings.value("ProxyType", false).toInt() == 0) {
            proxyUrl.setScheme("http");
        } else {
            proxyUrl.setScheme("socks5");
        }
        if (settings.value("ProxyAuthenticationRequired", false).toBool() == true) {
            proxyUrl.setUserName(settings.value("ProxyUsername", "").toString());
            proxyUrl.setPassword(settings.value("ProxyPassword").toString());
        }

        proxyArguments << "--proxy" << proxyUrl.toString();
    }

    QStringList networkArguments;
    if (settings.value("forceIpV4", false).toBool()) {
        networkArguments << "--force-ipv4";
    }

    arguments << proxyArguments << networkArguments;
    process->setArguments(arguments);
    process->setWorkingDirectory(QDir::tempPath());
    process->setProcessEnvironment(env);

    return process;
}

QString YoutubeDl::getVersion() {
    QProcess* youtubeDl = instance(QStringList("--version"));
    youtubeDl->start();
    youtubeDl->waitForFinished(10000);
    QString version = youtubeDl->readAllStandardOutput() + youtubeDl->readAllStandardError();
    youtubeDl->deleteLater();
    return version.replace("\n", "");
}

QString YoutubeDl::getPythonVersion() {
    // The PyInstaller bundle on macOS/Windows is self-contained, so there's
    // no separately-invocable Python interpreter to interrogate. Only the
    // Linux path still runs through a system python3.
    #if defined(Q_OS_WIN) || defined(Q_OS_MAC)
        return QString();
    #else
        QProcess python;
        python.setProgram(QStandardPaths::findExecutable("python3"));
        python.setArguments(QStringList("--version"));
        python.start();
        python.waitForFinished(10000);
        QString version = python.readAllStandardOutput() + python.readAllStandardError();
        return version.replace("\n", "");
    #endif
}

QString YoutubeDl::findPython() {
    #if defined(Q_OS_WIN) || defined(Q_OS_MAC)
        return QString();  // bundled into the PyInstaller binary, no path
    #else
        return QStandardPaths::findExecutable("python3");
    #endif
}

bool YoutubeDl::isInstalledAndCurrent(const QString& minVersion) {
    if (find().isEmpty()) return false;
    const QString installedVersion = getVersion();
    qDebug() << "Found yt-dlp" << installedVersion;
    // yt-dlp versions are date-stamped (YYYY.MM.DD[.N]) so lexical >= works.
    return installedVersion >= minVersion;
}

void YoutubeDl::startUpdate() {
    if (QSettings().value("disableYoutubeDlUpdate", false).toBool()) return;
    QProcess* process = instance(QStringList() << "--update");
    QObject::connect(process, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
                     process, [process] { process->deleteLater(); });
    process->start();
}

// ---------------------------------------------------------------------------
// Download / verify / install helpers (file-local).
// ---------------------------------------------------------------------------

// Parse a SHA2-256SUMS file (lines of "<64hex>  <filename>") and return the
// SHA256 hex for the requested filename. Returns "" if missing.
static QString sha256FromSumsFile(const QByteArray& sums, const QString& filename) {
    const QList<QByteArray> lines = sums.split('\n');
    for (const QByteArray& raw : lines) {
        QByteArray line = raw.trimmed();
        if (line.isEmpty()) continue;
        // Tolerate either one space or two spaces between hash and name.
        int sep = line.indexOf(' ');
        if (sep <= 0) continue;
        QByteArray hash = line.left(sep);
        QByteArray name = line.mid(sep).trimmed();
        if (hash.size() != 64) continue;
        if (QString::fromUtf8(name) == filename) {
            return QString::fromUtf8(hash);
        }
    }
    return QString();
}

// Remove a path whether it's a file, a symlink, or a directory. QDir::exists()
// returns false for non-directory paths, so a plain QDir::removeRecursively
// silently does nothing when the install dir is actually a stale file (e.g.
// the single-file yt-dlp_macos artifact a previous version of this branch
// downloaded). Returns true if the path is gone afterwards.
static bool wipePath(const QString& path) {
    QFileInfo info(path);
    if (!info.exists() && !info.isSymLink()) return true;
    if (info.isDir() && !info.isSymLink()) {
        return QDir(path).removeRecursively();
    }
    return QFile::remove(path);
}

// Extract a yt-dlp onedir zip into <installDir>/, with the actual binary at
// <installDir>/<binaryName>. We shell out to the platform's bundled archive
// tool — Qt has no public zip API and we'd rather not add a third-party dep
// just for this.
//
// `errorOut` receives a human-readable failure reason on error. Returns the
// absolute path to the extracted binary on success, "" otherwise (in which
// case all temp / partial state is wiped).
static QString extractYoutubeDlBundle(const QString& zipPath, const QString& installDir,
                                      const QString& binaryName, QString* errorOut) {
    auto fail = [&](const QString& msg) {
        if (errorOut) *errorOut = msg;
        wipePath(installDir);
        wipePath(installDir + ".extract");
        return QString();
    };

    // Wipe any previous install so we don't end up with a half-overlay.
    if (!wipePath(installDir)) {
        return fail(QStringLiteral("could not remove existing install at %1").arg(installDir));
    }
    if (!QDir().mkpath(installDir)) {
        return fail(QStringLiteral("could not create install dir %1").arg(installDir));
    }

    const QString tmpDir = installDir + ".extract";
    if (!wipePath(tmpDir) || !QDir().mkpath(tmpDir)) {
        return fail(QStringLiteral("could not prepare temp dir %1").arg(tmpDir));
    }

    // bsdtar ships with both Windows (10 1803+) and macOS, reads zip via
    // -xf, and accepts forward-slash paths on either platform.
    QProcess tar;
    tar.setProgram("tar");
    tar.setArguments(QStringList() << "-xf" << zipPath << "-C" << tmpDir);
    tar.start();
    if (!tar.waitForStarted(5000)) {
        return fail(QStringLiteral("could not start tar: %1").arg(tar.errorString()));
    }
    if (!tar.waitForFinished(120000)) {
        tar.kill();
        return fail(QStringLiteral("tar did not finish within 120s"));
    }
    if (tar.exitStatus() != QProcess::NormalExit || tar.exitCode() != 0) {
        const QString stderr_ = QString::fromLocal8Bit(tar.readAllStandardError()).trimmed();
        return fail(QStringLiteral("tar exited with %1: %2")
                    .arg(tar.exitCode())
                    .arg(stderr_.isEmpty() ? QStringLiteral("(no stderr)") : stderr_));
    }

    // PyInstaller's onedir layout is <bundle-root>/<binaryName>+_internal/.
    // yt-dlp's CI ships the zip with the bundle-root as the top-level entry,
    // but we glob for it defensively so naming changes don't break us.
    QDirIterator it(tmpDir, QStringList() << binaryName,
                    QDir::Files | QDir::NoSymLinks, QDirIterator::Subdirectories);
    if (!it.hasNext()) {
        return fail(QStringLiteral("extracted zip did not contain %1 under %2")
                    .arg(binaryName, tmpDir));
    }
    const QString foundBinary = it.next();
    const QString bundleRoot = QFileInfo(foundBinary).absolutePath();

    // Move bundle-root contents into installDir.
    QDir src(bundleRoot);
    for (const QString& entry : src.entryList(QDir::AllEntries | QDir::Hidden | QDir::NoDotAndDotDot)) {
        if (!QFile::rename(bundleRoot + "/" + entry, installDir + "/" + entry)) {
            return fail(QStringLiteral("failed to move %1 from extract dir to install dir")
                        .arg(entry));
        }
    }
    wipePath(tmpDir);
    return installDir + "/" + binaryName;
}

// ---------------------------------------------------------------------------
// YoutubeDlDownloader
// ---------------------------------------------------------------------------

YoutubeDlDownloader::YoutubeDlDownloader(QObject* parent)
    : QObject(parent),
      nam(new QNetworkAccessManager(this)),
      sumsReply(nullptr),
      artifactReply(nullptr),
      isArchive(false),
      reported(false)
{
    assetName = YoutubeDl::expectedReleaseAssetName();
    installPath = YoutubeDl::installDir();
    binaryName = YoutubeDl::bundledBinaryName();
    isArchive = assetName.endsWith(".zip");

    baseUrl = QSettings().value(
        "youtubeDlBaseUrl",
        "https://github.com/yt-dlp/yt-dlp/releases/latest/download/").toString();

    // The downloaded artifact (script or zip) lands in the AppData root as a
    // .partial; for the zip case extractYoutubeDlBundle recreates installPath.
    const QString downloadDir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    QDir().mkpath(downloadDir);
    partialPath = downloadDir + "/" + assetName + ".partial";
}

void YoutubeDlDownloader::reportFailure(const QString& message) {
    if (reported) return;
    reported = true;
    emit failed(message);
}

void YoutubeDlDownloader::start() {
    // Phase 1: fetch SHA2-256SUMS so we know what the artifact must hash to.
    // Both this and the artifact download go through GitHub HTTPS — the SHA
    // check catches CDN tampering / mid-download corruption; the GPG-signed
    // SHA2-256SUMS.sig would catch a source compromise but verifying that
    // requires an OpenPGP library Qt doesn't ship.
    sumsReply = nam->get(QNetworkRequest(QUrl(baseUrl + "SHA2-256SUMS")));
    connect(sumsReply, &QNetworkReply::finished, this, &YoutubeDlDownloader::onSumsFinished);
}

void YoutubeDlDownloader::onSumsFinished() {
    sumsReply->deleteLater();
    if (sumsReply->error() != QNetworkReply::NoError) {
        reportFailure(tr("Could not download SHA2-256SUMS: %1").arg(sumsReply->errorString()));
        return;
    }

    const QString expectedSha = sha256FromSumsFile(sumsReply->readAll(), assetName);
    if (expectedSha.isEmpty()) {
        reportFailure(tr("SHA2-256SUMS does not contain an entry for %1").arg(assetName));
        return;
    }
    downloadArtifact(expectedSha);
}

void YoutubeDlDownloader::downloadArtifact(const QString& expectedSha) {
    // Stream to a .partial file so we never leave a half-written artifact.
    QFile* tempFile = new QFile(partialPath, this);
    if (!tempFile->open(QFile::WriteOnly | QFile::Truncate)) {
        reportFailure(tr("Unable to write to %1").arg(tempFile->fileName()));
        delete tempFile;
        return;
    }

    artifactReply = nam->get(QNetworkRequest(QUrl(baseUrl + assetName)));

    connect(artifactReply, &QNetworkReply::readyRead, this, [this, tempFile] {
        tempFile->write(artifactReply->readAll());
    });
    connect(artifactReply, &QNetworkReply::downloadProgress, this,
            &YoutubeDlDownloader::progress);
    connect(artifactReply, &QNetworkReply::sslErrors, this, [this](const QList<QSslError>& errors) {
        QStringList details;
        for (const QSslError& e : errors) details << e.errorString();
        reportFailure(tr("SSL error while downloading %1:\n%2")
                      .arg(assetName, details.join("\n")));
    });
    connect(artifactReply, &QNetworkReply::finished, this, [this, tempFile, expectedSha] {
        artifactReply->deleteLater();
        tempFile->close();

        if (artifactReply->error() != QNetworkReply::NoError) {
            tempFile->remove();
            delete tempFile;
            reportFailure(tr("Error downloading %1: %2").arg(assetName, artifactReply->errorString()));
            return;
        }
        delete tempFile;
        onArtifactFinished(expectedSha);
    });
}

void YoutubeDlDownloader::onArtifactFinished(const QString& expectedSha) {
    // Verify the SHA-256 of the downloaded artifact against the sums entry.
    QFile partial(partialPath);
    if (!partial.open(QFile::ReadOnly)) {
        partial.remove();
        reportFailure(tr("Could not re-open %1 for hashing").arg(partialPath));
        return;
    }
    QCryptographicHash hash(QCryptographicHash::Sha256);
    hash.addData(&partial);
    partial.close();

    const QString actualSha = QString::fromLatin1(hash.result().toHex());
    if (actualSha.compare(expectedSha, Qt::CaseInsensitive) != 0) {
        partial.remove();
        reportFailure(tr(
            "Downloaded %1 failed SHA-256 verification.\n"
            "Expected: %2\nGot:      %3\n"
            "This usually means GitHub published a newer release between "
            "the SHA2-256SUMS fetch and the artifact fetch — please retry."
            ).arg(assetName, expectedSha, actualSha));
        return;
    }

    const QString error = finalizeInstall();
    if (!error.isEmpty()) {
        reportFailure(error);
        return;
    }
    if (!reported) emit succeeded();
}

QString YoutubeDlDownloader::finalizeInstall() {
    QString finalBinaryPath;
    if (isArchive) {
        // The artifact is a onedir zip; extract it into installPath and
        // discard the zip.
        QString extractError;
        finalBinaryPath = extractYoutubeDlBundle(partialPath, installPath, binaryName, &extractError);
        QFile::remove(partialPath);
        if (finalBinaryPath.isEmpty()) {
            return tr("Failed to extract %1 into %2:\n%3")
                    .arg(assetName, installPath, extractError);
        }
    } else {
        // The artifact IS the script (Linux). Move it into place.
        finalBinaryPath = installPath + "/" + binaryName;
        QDir().mkpath(installPath);
        QFile::remove(finalBinaryPath);
        if (!QFile::rename(partialPath, finalBinaryPath)) {
            QFile::remove(partialPath);
            return tr("Could not move %1 to %2").arg(partialPath, finalBinaryPath);
        }
    }

    #if !defined(Q_OS_WIN)
        QFile::setPermissions(finalBinaryPath,
            QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner
            | QFile::ReadGroup | QFile::ExeGroup
            | QFile::ReadOther | QFile::ExeOther);
    #endif
    #if defined(Q_OS_MAC)
        // QNetworkAccessManager writes via plain POSIX write(2) so the file
        // typically isn't quarantined to begin with, but strip the xattr
        // defensively in case some future Qt / macOS combination starts
        // adding it. removexattr is the documented Darwin syscall.
        ::removexattr(finalBinaryPath.toUtf8().constData(),
                      "com.apple.quarantine", XATTR_NOFOLLOW);
    #endif

    // Reset the cached path so the next find() re-resolves to the new binary.
    YoutubeDl::path.clear();
    return QString();
}
