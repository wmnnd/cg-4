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
    // Filename used for the downloaded yt-dlp artifact in AppDataLocation,
    // and the filename to request from the GitHub release. Differs per OS
    // because we now ship the PyInstaller binary on macOS / Windows and
    // only fall back to the .py script on Linux.
    static QString expectedReleaseAssetName();

    static QString path;
    static QString pythonCaFile;
};

#endif // YOUTUBEDL_H
