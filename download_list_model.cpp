#include "download_list_model.h"

#include <QSize>

DownloadListModel::DownloadListModel(ClipGrab* cg, QObject *parent)
    : QAbstractItemModel(parent), cg(cg)
{

    connect(cg, &ClipGrab::downloadEnqueued, this, [=] {
        if (cg->downloads.isEmpty()) return;
        video* enqueuedVideo = cg->downloads.last();
        beginInsertRows(QModelIndex(), 0, 0);
        endInsertRows();

        connect(enqueuedVideo, &video::downloadProgressChanged, this, [=] {
            int idx = cg->downloads.indexOf(enqueuedVideo);
            if (idx < 0) return;
            int row = cg->downloads.size() - idx - 1;
            if (row >= 0 && row < cg->downloads.size()) {
                emit dataChanged(createIndex(row, 4), createIndex(row, 4));
            }
        });


        connect(enqueuedVideo, &video::stateChanged, this, [=] {
            int idx = cg->downloads.indexOf(enqueuedVideo);
            if (idx < 0) return;
            int row = cg->downloads.size() - idx - 1;
            if (row >= 0 && row < cg->downloads.size()) {
                emit dataChanged(createIndex(row, 0), createIndex(row, 4));
            }
        });
    });

    connect(cg, &ClipGrab::downloadAboutToBeRemoved, this, [=](video* removedVideo) {
        int idx = cg->downloads.indexOf(removedVideo);
        if (idx < 0) return;
        int row = cg->downloads.size() - idx - 1;
        if (row < 0 || row >= cg->downloads.size()) return;
        beginRemoveRows(QModelIndex(), row, row);
    });

    connect(cg, &ClipGrab::downloadRemoved, this, [=] {
        endRemoveRows();
    });
}

DownloadListModel::~DownloadListModel()
{}

Qt::ItemFlags DownloadListModel::flags(const QModelIndex &index) const
{
    if (!index.isValid())
        return Qt::NoItemFlags;

    return QAbstractItemModel::flags(index);
}

QModelIndex DownloadListModel::index(int row, int column, const QModelIndex &parent) const {
    if (!hasIndex(row, column, parent)) {
        return QModelIndex();
    }

    return createIndex(row, column);
}

QModelIndex DownloadListModel::parent(const QModelIndex &/*index*/) const {
    return QModelIndex();
}

int DownloadListModel::rowCount(const QModelIndex &parent) const {
    if (parent.isValid()) return 0;
    return cg->downloads.size();
}

int DownloadListModel::columnCount(const QModelIndex & /*parent*/) const {
    return header.size();
}

QVariant DownloadListModel::data(const QModelIndex &index, int role) const {
    if (!index.isValid()) {
        return QVariant();
    }

    if (role == Qt::SizeHintRole) {
        switch (index.column()) {
        case 4:
            return QSize(220, 24);
        default:
            return QVariant();
        }
    }

    if (role != Qt::DisplayRole) return QVariant();

    int dataIndex = cg->downloads.size() - index.row() - 1;
    if (dataIndex < 0 || dataIndex >= cg->downloads.size()) return QVariant();
    video* video = cg->downloads.at(dataIndex);
    switch (index.column()) {
    case 0:
        return video->getPortalName();
    case 1:
        return video->getTitle();
    case 2:
        return video->getSelectedQualityName();
    case 3:
        return video->getTargetFormatName();
    case 4:
        switch (video->getState()) {
        case video::state::downloading: {
            qint64 downloadProgress = video->getDownloadProgress();
            qint64 downloadSize = video->getDownloadSize();

            if (downloadSize == 0) return tr("Starting ...");

            QString percentage = QString::number(downloadProgress * 100.0 / downloadSize, 'f', 1);
            if (percentage == "100.0") percentage = "99.9";
            return percentage + QChar(0x2009) + "%(" + cg->humanizeBytes(downloadProgress) + "/" + cg->humanizeBytes(downloadSize) + ")";
        }
        case video::state::converting:
            return tr("Converting ...");
        case video::state::finished:
            return tr("Finished");
        case video::state::paused:
            return tr("Paused");
        case video::state::canceled:
            return tr("Canceled");
        case video::state::unfetched:
            return tr("Waiting");
        default:
            return tr("Failed");
        }
    default: return "";
    }
}

QVariant DownloadListModel::headerData(int section, Qt::Orientation orientation, int role) const {
    if (orientation == Qt::Horizontal && role == Qt::DisplayRole) {
        if (section < 0 || section >= header.size()) return QVariant();
        return header.at(section);
    }

    return QVariant();
}

video* DownloadListModel::getVideo(const QModelIndex index) {
    if (!index.isValid()) return nullptr;
    int dataIndex = cg->downloads.size() - index.row() - 1;
    if (dataIndex < 0 || dataIndex >= cg->downloads.size()) return nullptr;
    return cg->downloads.at(dataIndex);
}
