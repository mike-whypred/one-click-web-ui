# Open WebUI for Windows (one-click install)

This sets up a private AI chat app on your own PC. After it is installed, it
runs fully on your computer, your chats stay on your machine, and you do not
need the internet to use it.

It installs two things for you automatically:

- **Ollama**, the engine that runs the AI model.
- **Open WebUI**, the chat website that runs locally in your browser.

You do not need Docker, you do not need Python, and you do not need to type any
commands.

---

## What you need

- A 64-bit Windows 10 or Windows 11 PC.
- About 15 GB of free disk space (the AI model is large).
- An internet connection for the first install only.

---

## How to install

1. Double-click **`Install-OpenWebUI.bat`**.

2. **Windows may show a blue "Windows protected your PC" box (SmartScreen).**
   This is normal for a small tool that is not signed by a big company. To
   continue:
   - Click **More info**.
   - Click **Run anyway**.

3. A black window opens and shows progress. The first install downloads several
   large files (including the AI model, about 10 GB), so it can take a while
   depending on your internet speed. You can leave it running and do other
   things.

4. When it finishes it says **"Success"** and creates a shortcut called
   **Open WebUI** on your desktop.

That is it. You will not be asked for an administrator password; everything
installs just for your user account.

---

## How to use it

1. Double-click the **Open WebUI** shortcut on your desktop.
2. The first time, it may take a few moments to start. Your browser then opens
   to the chat app.
3. The first time you open it, create a local account (any email and password
   you like). This account lives only on your PC; it is not sent anywhere.
4. Pick the model from the dropdown at the top and start chatting.

You can close the browser and reopen the shortcut any time. After a restart,
just use the shortcut again.

---

## Using it without internet

After the first install, you can disconnect from the internet and it still
works. The AI model runs entirely on your PC.

---

## Adding more AI models

You can add more models from inside the app, no command line needed:

1. Open the app from the desktop shortcut.
2. Click your name (bottom left), then **Admin Panel**.
3. Go to **Settings**, then **Models**.
4. Use **Pull a model from Ollama.com**, type a model name (for example
   `llama3.2` or `qwen2.5`), and confirm. It downloads in the background.
5. New models appear in the dropdown at the top of the chat screen.

---

## Where your data is stored

Everything is local to your user account:

- Your chats and login: `%LOCALAPPDATA%\OpenWebUI\data`
- The app and its private Python: `%LOCALAPPDATA%\OpenWebUI`
- The downloaded AI models: `%USERPROFILE%\.ollama\models`

(You can paste those paths into the File Explorer address bar to open them.)

---

## If something goes wrong

If the install or launch fails, you will get a plain-language message and the
location of a **log file**. The log files are here:

```
%LOCALAPPDATA%\OpenWebUI\logs
```

Send the most recent log file if you need help.

Common things to try:

- Make sure you are connected to the internet for the first install.
- Make sure you have enough free disk space.
- If your antivirus blocked a step, allow the installer and run it again.
- Running the installer again is safe. It skips anything already done.

---

## How to uninstall

Double-click **`Uninstall-OpenWebUI.bat`**. It removes the app, your local
chats, and the desktop shortcut. It will ask whether you also want to delete
the downloaded AI models (to reclaim disk space).

Ollama itself is left installed (you may use it for other things). To remove it
too, go to Windows **Settings**, **Apps**, and uninstall **Ollama**.
