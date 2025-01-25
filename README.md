# Instablue

A very quick-and-dirty Ruby script that takes an Instagram post dump and reposts it to BlueSky. It focuses on just the basics that I needed myself, but I've put it up on GitHub just in case someone else finds it useful too.

Command line knowledge and Ruby 3.0 or later are assumed. This was written and tested on macOS but should work fine on Linux or other Unix/Unix-like systems. Windows is probably OK but YMMV.



## Limitations

* BlueSky at the time of writing supports up to 300 characters per post.
* A post can have between one and and four images attached, *OR* or one movie, or no attachments.

That is far tighter than Instagram's limits, so:

* Text is split at word boundaries to keep to 300 characters per per post or less.
* A prefix of `Copied from Instagram:` is added to post texts at the start, or for posts with no text, the text is simply, `Copied from Instagram`.
* If more than one post is needed - e.g. because the text exceeds 300 characters at the word boundary - then a root post with in-thread replies are used, with the commonly-seen convention of `(1/4)`-style ("Post number X out of Y posts in total") used as (again) a further prefix for each piece of posted text. So, your first post's text would read something like - "(1/2) Copied from Instagram: ...your text here..." with the second post in this hypothetical thread reading, "(2/2) ...your text continues...".
* Images are posted before videos. Up to four images are used per post, splitting using a thread as described above if need be. Image quality may be lower than the original photos from Instagram due to the very low 1,000,000 byte limit on photos imposed by the BlueSky AT Protocol implementation.
* Videos are posted last. Cover photos are *not* exported - they're deliberately skipped.

If an error occurs when a "root" post has successfully been made, but one of the 'thread' related posts fails, then you'll need to clean up the partial post manually before restarting. See later for information on restarting and retries.



## Prerequisites
### Ruby 3.x

Instablue was developed on Ruby 3.4 on macOS, installed using [RVM](https://rvm.io/) to manage versions, but older and newer Ruby 3 versions should work fine as should other version and package managers on macOS (e.g. [asdf](https://asdf-vm.com)) or other operating systems.

### Image Magick

BlueSky has an image size limit of about a megabyte which Instagram images in newer posts will often exceed. Image quality must be lowered to reach the size limit if an image is too big, by re-encoding via the MiniMagick gem. This relies upon the prior installation of [ImageMagick](https://imagemagick.org). On macOS using [HomeBrew](https://brew.sh) you can install this easily with `brew install imagemagick`. Otherwise, please consult ImageMagick's installation documentation for help.

### Gems

Install required Ruby gems for Instablue by running command `bundle install` from inside the Instablue folder.

### Instaloader

You will need to have [Instaloader](https://instaloader.github.io/) installed. Very helpfully there is a macOS HomeBrew package for it, so `brew install instaloader` might be all you need. Otherwise, as ever, read the Instaloader installation documentation for further help.

### Dump your Instagram data

Before running Instablue, build a dump of your Instagram posts using Instaloader. The dump will be put into a folder named from your instagram username. The command I've been using is:

```sh
instaloader --fast-update <profile-id> --login <profile-id> --password <insta-password>
```

...for example, for my account `adh1003` I used:

```sh
instaloader --fast-update  adh1003 --login adh1003 --password ...redacted...
```

...resulting in a folder called `adh1003` built inside the current working directory, inside which are a series of files that look a bit like this:

```
2017-03-18_00-49-40_UTC.json.xz
2017-03-18_00-49-40_UTC.txt
2017-03-18_00-49-40_UTC_1.jpg
2017-03-18_00-49-40_UTC_2.jpg
2017-03-18_00-49-40_UTC_3.jpg
2017-03-18_00-49-40_UTC_4.jpg
2017-03-18_10-16-49_UTC.jpg
2017-03-18_10-16-49_UTC.json.xz
2017-03-18_10-16-49_UTC.txt
2017-03-19_08-06-49_UTC.jpg
2017-03-19_08-06-49_UTC.json.xz
2017-03-19_08-06-49_UTC.txt
```

...that is to say - a UTC date-time based set of filenames that group posts, with JPEG format images and MP4 format movies. No other filetypes are supported. The extensive metadata in the compressed JSON is ignored. The text files contain your post's associated text. This is exported to Bluesky _without_ any attempt to recognise links, tags or similar - it's just plain text.

See [the Instaloader usage guide](https://instaloader.github.io/basic-usage.html#basic-usage) for more.



## Configuration

BlueSky communication is managed by the gem [minisky](https://github.com/mackuba/minisky) and require authenticated access to your BlueSky account. Create a file called `bluesky_creds.yml` alongside "instablue.rb" and populate it with your BlueSky login e-mail address and plain text password as shown below (this file is in `.gitignore` so there's no chance of accidentally committing it anywhere).

```yaml
--
id: your@bluesky.login.email
pass: your-bluesky-password

```

Next, edit `instablue.rb`.

* Change `BASE_DIR` to point to the folder that Instaloader created with your instagram data
* If you use a server other than `bsky.social`, then edit `BLUESKY_SERVER` just below `BASE_DIR` accordingly
* Read about the SLEEP_BETWEEN_POSTS constants if you want to change / remove the between-post delay.



## Running the reposter

Run:

```sh
bundle exec ruby instablue.rb
```

...and Instablue will start parsing your Instaloader data dump, starting with your oldest Instagram post and working through in order towards the newest. I recommend hitting Ctrl+C after the first successful post, looking in the output in the terminal for the HTTPS URL of the root post made to BlueSky and visiting that to check that things look satisfactory.

### Re-runs and errors

While Instablue runs, it writes text files dumping the date-time of each file it _starts_ to process, then those that it _successfully finished_. When you re-run, anything that's been finished before is ignored. Anything that started but did not finished is asked about, each time, for a Y/N answer about whether or not it should be retried.

In addition, **CSV file `results.csv` tracks successful posts** and can be loaded into a CSV viewer to get the HTTPS URLs in `bsky.app` that show each of your individual posts (making it easier to delete things you don't like).

For a completely clean start, delete:

* `posts_started.yml`
* `posts_finished.yml`
* `results.csv`

...and run Instablue again. Note that the terminal dumps a fair bit of information for each post, including HTTPS URLs as previously mentioned to visit a specific post in case you want to delete something before the retry.
