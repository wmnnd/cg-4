#ifndef YOUTUBEDL_H
#define YOUTUBEDL_H

#include <QtCore>
#include <QDebug>

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
    // Directory under AppDataLocation that holds the extracted onedir
    // bundle. On Linux this is just AppDataLocation since we keep the
    // single-file script there.
    static QString installDir();

    static QString path;
};

#endif // YOUTUBEDL_H
