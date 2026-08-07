#ifndef MESSAGE_DIALOG_H
#define MESSAGE_DIALOG_H

#include <QDialog>
#include <QString>
#include <QUrl>

class QNetworkAccessManager;

namespace Ui {
class messageDialog;
}

class messageDialog : public QDialog
{
    Q_OBJECT

public:
    explicit messageDialog(QWidget *parent = nullptr);
    ~messageDialog();
    void setUrl(QUrl url);
    void setLinkPolicy(QString);

private:
    Ui::messageDialog *ui;
    QNetworkAccessManager* nam;
    QUrl loadedUrl;
    QString linkPolicy;

    void load(const QUrl & url);

private slots:
    void handleLink(const QUrl & url);
};

#endif // MESSAGE_DIALOG_H
