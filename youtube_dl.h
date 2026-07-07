#ifndef YOUTUBEDL_H
#define YOUTUBEDL_H

#include <QtCore>
#include <QDebug>

class QNetworkAccessManager;
class QNetworkReply;

class YoutubeDl
{
public:
    YoutubeDl();

    static QProcess* instance(QStringList arguments);
    static QProcess* instance(QString path, QStringList arguments);
    static QString getVersion();
    static QString getPythonVersion();   // returns interpreter info on Linux, "" elsewhere
    static QString find(bool force = false);
    static QString findPython();
    // Filename of the GitHub release asset to download. The macOS/Windows
    // builds switched to the onedir .zip variants because PyInstaller's
    // onefile bundle re-extracts on every launch, costing 2–5 s on macOS.
    static QString expectedReleaseAssetName();
    // Name of the binary inside the extracted onedir bundle (or, on Linux,
    // the script itself). Used to locate the actual executable in `find()`.
    static QString bundledBinaryName();
    // Directory that holds the downloaded yt-dlp. On macOS/Windows it's a
    // per-asset, per-arch folder for the extracted onedir bundle — e.g.
    // "<AppData>/yt-dlp_macos_arm64" — deliberately NOT "<AppData>/yt-dlp",
    // which is the file older releases download the plain script to (kept
    // distinct so a downgrade to an old build still works). On Linux it's
    // AppDataLocation itself, where the single-file script has always lived.
    static QString installDir();

    // True when a usable yt-dlp is present and at least minVersion. When it
    // returns true the caller can skip the download entirely.
    static bool isInstalledAndCurrent(const QString& minVersion);
    // Fire-and-forget self-update ("yt-dlp -U"). No-op when the
    // disableYoutubeDlUpdate setting is set. The spawned process cleans
    // itself up when it finishes.
    static void startUpdate();

    static QString path;
};

// Downloads (and verifies + installs) the yt-dlp binary/bundle from the
// GitHub release. Owns the whole network + filesystem flow; the UI layer
// only connects to the signals to drive a progress bar and report errors.
class YoutubeDlDownloader : public QObject
{
    Q_OBJECT
public:
    explicit YoutubeDlDownloader(QObject* parent = nullptr);

    // Kick off the two-phase download (SHA2-256SUMS, then the artifact).
    // Exactly one of succeeded() / failed() is emitted.
    void start();

signals:
    void progress(qint64 received, qint64 total);
    void succeeded();
    void failed(const QString& message);

private:
    void onSumsFinished();
    void downloadArtifact(const QString& expectedSha);
    void onArtifactFinished(const QString& expectedSha);
    QString finalizeInstall();          // returns "" on success, else error text
    void reportFailure(const QString& message);

    QNetworkAccessManager* nam;
    QNetworkReply* sumsReply;
    QNetworkReply* artifactReply;

    QString assetName;
    QString installPath;
    QString binaryName;
    QString partialPath;
    QString baseUrl;
    bool isArchive;
    bool reported;                      // guards against double terminal emit
};

#endif // YOUTUBEDL_H
