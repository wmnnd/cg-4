#include "message_dialog.h"
#include "ui_message_dialog.h"

#include <QDesktopServices>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QShowEvent>
#include <QTextBrowser>

#include "mac_colorspace.h"

messageDialog::messageDialog(QWidget *parent) :
    QDialog(parent),
    ui(new Ui::messageDialog),
    nam(new QNetworkAccessManager(this)),
    linkPolicy("open")
{
    ui->setupUi(this);
    ui->textBrowser->setOpenExternalLinks(false);
    ui->textBrowser->setOpenLinks(false);
    connect(ui->textBrowser, &QTextBrowser::anchorClicked,
            this, &messageDialog::handleLink);
}

messageDialog::~messageDialog()
{
    delete ui;
}

void messageDialog::showEvent(QShowEvent* event)
{
    QDialog::showEvent(event);
    // Colour-manage this window as sRGB so the message's colours render the
    // same as they do in a browser instead of oversaturating on wide-gamut
    // (Display P3) macOS screens. No-op off macOS; safe to call on each show.
    setWindowSRGBColorSpace(this);
}

void messageDialog::setUrl(QUrl url)
{
    load(url);
}

void messageDialog::setLinkPolicy(QString policy) {
    linkPolicy = policy;
}

void messageDialog::load(const QUrl & url)
{
    loadedUrl = url;
    QNetworkReply* reply = nam->get(QNetworkRequest(url));
    connect(reply, &QNetworkReply::finished, this, [this, reply] {
        reply->deleteLater();
        if (reply->error() != QNetworkReply::NoError) {
            ui->textBrowser->setHtml(
                tr("<p>Could not load message: %1</p>").arg(reply->errorString()));
            return;
        }
        // QTextBrowser renders Qt's HTML subset; the control-server-pushed
        // content lives in that subset by convention.
        ui->textBrowser->setHtml(QString::fromUtf8(reply->readAll()));
    });
}

void messageDialog::handleLink(const QUrl & url)
{
    // "follow" — load the new URL in-place. "open-external" — load in-place
    // only when the host matches the original, otherwise hand off to the
    // system browser. "open" (default) — always hand off externally.
    if (linkPolicy == "follow"
            || (linkPolicy == "open-external" && url.host() == loadedUrl.host())) {
        load(url);
    } else {
        QDesktopServices::openUrl(url);
    }
}
