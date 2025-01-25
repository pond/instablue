# This aims to be relatively simple, rather than efficient. Any small gains in
# processing on the Ruby side are completely eclipsed by API call wait times.
#
require 'time'
require 'csv'
require 'yaml'
require 'debug'

require 'minisky'
require 'fastimage'
require 'mini_magick'
require 'video_dimensions'

# =============================================================================
# CONSTANTS
# =============================================================================

BASE_DIR            = '/Users/adh1003/adh1003'
BLUESKY_SERVER      = 'bsky.social'
BLUESKY_CREDS_FILE  = File.join(File.dirname(__FILE__), 'bluesky.yml').to_s
CSV_RESULTS_FILE    = File.join(File.dirname(__FILE__), 'results.csv').to_s
STARTED_FILE        = File.join(File.dirname(__FILE__), 'posts_started.yml').to_s
FINISHED_FILE       = File.join(File.dirname(__FILE__), 'posts_finished.yml').to_s
MAX_CHARS_IN_TEXT   = 300
MAX_PHOTOS_PER_POST = 4
MAX_VIDEOS_PER_POST = 1
MAX_PHOTO_BYTES     = 1_000_000
BSKY_CLIENT         = Minisky.new(BLUESKY_SERVER, 'bluesky_creds.yml')
COPY_TEXT_IF_EMPTY  = 'Copied from Instagram'
COPY_TEXT_AS_PREFIX = 'Copied from Instagram: '

# Instablue doesn't tend to encounter explicit post rate limiting but even so,
# you might want to sleep between each Instagram post (Bluesky thread). Set to
# 0 -> don't, else this is an inter-post sleep in seconds. Ctrl+C becomes
# "safer" while sleeping since there's no started-but-unfinished file and no
# API calls are underway, so a sleep delay can be handy if you sometimes want
# to deliberately halt posting fully, intending to resume later.
#
SLEEP_BETWEEN_POSTS = 10#

# This is really just for me during debugging sometimes and generally speaking
# the script will *not* work if this is set to 'false' in released versions.
#
USE_REAL_API_CALLS  = true

# If using Minisky for the first time, it can break when we attempt to post for
# the first time, as the post body requires the user's DID but that isn't set
# up yet and the payload typically ends up with a "null" in there, causing a
# failure. I wouldn't expect that, given synchronous execution and the order of
# evaluation, but it happens consistently. So - the call below forces the
# client to fetch the DiD right now. This seems to work around the problem.
#
BSKY_CLIENT.user.did

# =============================================================================
# HELPER METHODS
# =============================================================================

# https://github.com/bluesky-social/atproto/discussions/2523#discussioncomment-9552109
#
# Convert - at://<DID>/<COLLECTION>/<RKEY>
# To      - https://sky.app/profile/<DID>/post/<RKEY>
#
# Example: at://did:plc:v3ga63twqoq3q3fdt5vjh463/app.bsky.feed.post/3lgi2cpxrfk22
#       => https://bsky.app/profile/did:plc:v3ga63twqoq3q3fdt5vjh463/post/3lgi2cpxrfk22
#
def at_to_https(at_uri)
  parts = at_uri.match(/^at\:\/\/(did\:.*?)\/.*?\/(.*$)/)
  did   = parts[1]
  rkey  = parts[2]

  return "https://bsky.app/profile/#{did}/post/#{rkey}"
end

# =============================================================================
# MAIN SCRIPT
# =============================================================================

# Parse all filenames into a set of unique UTC Time objects, oldest first.
#
puts "Reading all dates..."

all_pathnames = Dir.glob(File.join(BASE_DIR, '**'))
date_times    = all_pathnames.map do | path |
  date_time_str = File.basename(path).scan(/(\d\d\d\d-\d\d-\d\d_\d\d-\d\d-\d\d_UTC).*/).flatten.first

  if date_time_str.nil?
    nil
  else
    Time.strptime(date_time_str, '%Y-%m-%d_%H-%M-%S_%Z')
  end
end

date_times.uniq!
date_times.compact!
date_times.sort!

puts "Loading progress files if present..."

image_tempfile = nil
posts_started  = YAML.load(File.read(STARTED_FILE )) rescue []
posts_finished = YAML.load(File.read(FINISHED_FILE)) rescue []
csv_string     = File.read(CSV_RESULTS_FILE) rescue ''

if csv_string == ''
  csv_string = CSV.generate_line(['Date', 'HTTPS URL', 'Snippet', 'AT URI'])
end

# For each of those dates, now reconstruct base filenames and extract the set
# of description, JSON bundle and media items.
#
puts "Processing individual dates..."

date_times.each_with_index do | post_date_time, post_date_time_index |
  if posts_finished.include?(post_date_time.iso8601)
    puts "WARNING: Already posted #{post_date_time} -> skipping"
    next # NOTE EARLY LOOP RESTART
  end

  if posts_started.include?(post_date_time.iso8601)
    puts "HALT: Post of #{post_date_time} started but did not appear to finish."
    puts 'It may or may not have worked.'
    puts 'Retry this post [Y]/[N]?'

    input = gets.chomp().downcase
    next if input == 'n' # NOTE EARLY LOOP RESTART
  else
    posts_started << post_date_time.iso8601
    File.write(STARTED_FILE, YAML.dump(posts_started))
  end

  filename_match = post_date_time.strftime('%Y-%m-%d_%H-%M-%S_%Z')
  post_pathnames = Dir.glob(File.join(BASE_DIR, "#{filename_match}*")).sort

  description = post_pathnames.find     { |p| p.end_with?('.txt'    ) }
  json        = post_pathnames.find     { |p| p.end_with?('.json.xz') }
  photos      = post_pathnames.find_all { |p| p.end_with?('.jpg'    ) }
  videos      = post_pathnames.find_all { |p| p.end_with?('.mp4'    ) }

  # See if there are any data types we didn't recognise, indicating that this
  # code needs updating to understand it.
  #
  found_pathnames = ([description, json].compact + photos + videos).sort

  if found_pathnames != post_pathnames
    puts "MISMATCH"
    puts post_pathnames.inspect
    puts "vs"
    puts found_pathnames.inspect
    puts "DIFF"
    puts (post_pathnames - found_pathnames).inspect
    raise "Exit due to mismatch; Instagram source dump not fully understood"
  end

  # Work out how to break this up into an AT Protocol set of calls given the
  # significant constraints in Jan 2025; per post, only either up to 4 images
  # or one video (but constants are used - see top of file - to make it
  # easier to change this in future, albeit hard-coding the assumption for
  # now that mixed media is not supported - only photos *or* videos).
  #
  # In my own Instagram feed, I tend to either post reels or video posts
  # with no other media; or I post images, that maybe have videos in the mix
  # later. Many content creators are more video-first but that doesn't fit my
  # usage. Further, I don't usually tailor cover photos for the video and in
  # BlueSky there's no such concept, so this would bloat out a video-only
  # post by a thread containing an image part just for the cover photo. Some
  # content creators tailor cover photos heavily - in some cases using an
  # eye-catching photo that isn't even from the video. This is disingenuous,
  # always annoys me and is something I'm not interested in supporting. The
  # TL;DR is this:
  #
  # * Photos will get sent before videos
  # * Video cover photos (identified by a matching JPEG filename) are skipped
  #
  videos.each do | video_pathanme |
    photos.reject! do | photo_pathname |
      photo_leaf = File.basename(photo_pathname, File.extname(photo_pathname))
      video_leaf = File.basename(video_pathanme, File.extname(video_pathanme))
      video_leaf == photo_leaf
    end
  end

  # There's a limit of MAX_CHARS_IN_TEXT imposed apprently by current BlueSky
  # rather than the protocol, but exceeding this might cause layout issues
  # in the app. Descriptions longer than this are therefore split. As we
  # go through posts, we may be using continued descriptions, or just a ref
  # to thenprior higher-in-thread description now all posted, or even have
  # run out of media and be posting entries just to finish up the text part.
  #
  post_text = File.read(description) unless description.nil?
  post_text&.strip!

  if post_text.nil? || post_text == ''
    post_text = COPY_TEXT_IF_EMPTY
  else
    post_text = COPY_TEXT_AS_PREFIX + post_text
  end

  # When we split a Ruby string into words via simply using spaces, newlines
  # are consumed (via String#split, at least). We want to preserve all input
  # newlines in output, but split posts cleanly on word boundaries; so we
  # process input line by line, splitting words within that.
  #
  post_texts                  = []
  text_part                   = ''
  worst_case_part_append_size = '(99/99)'.size
  line_count_total            = post_text.each_line.count
  line_count_current          = 1

  post_text.each_line do | line |
    words = line.split(' ')
    words.each do | word |
      # "+1" for space or newline terminator
      if text_part.size + word.size + 1 + worst_case_part_append_size > MAX_CHARS_IN_TEXT
        post_texts << text_part.strip # Part indicator gets added later
        text_part = ''
      end

      text_part << word << ' '
    end

    # When we finish a line, make sure a newline is added to the string. Since
    # 'text_part' already terminates in a space, it can be swapped for newline
    # - no length change, so no worries aobut exceeding MAX_CHARS_IN_TEXT.
    #
    # We don't do this if we're on the last line of the input text, obviously.
    #
    if line_count_current < line_count_total && text_part.size > 0
      text_part = text_part.strip + "\n"
    end

    line_count_current += 1
  end

  post_texts << text_part if text_part.size > 0

  # Now walk through post texts, images and videos, keeping posting until all
  # are consumed.
  #
  root_post_uri = nil # Records URI of root post in what may become a thread
  root_post_cid = nil # Likewise records CID
  text_index    = 0
  photo_index   = 0
  video_index   = 0
  parts_count   = [
    post_texts.size,
    (photos.size.to_f / MAX_PHOTOS_PER_POST).ceil() + (videos.size.to_f / MAX_VIDEOS_PER_POST).ceil()
  ].max()

  puts "="*80
  puts "#{post_date_time_index + 1} of #{date_times.size}"
  puts "="*80

  loop do
    raw_post_text     = post_texts[text_index]
    post_attachments  = photos[photo_index...(photo_index + MAX_PHOTOS_PER_POST)] # Send photos first
    shifted_date_time = (post_date_time + (1 * text_index))
    actual_post_text  = if parts_count > 1
      "(#{text_index + 1}/#{parts_count}) #{raw_post_text&.strip&.chomp('.')}".strip
    else
      raw_post_text&.strip
    end

    if post_attachments&.any? == true
      photo_index += MAX_PHOTOS_PER_POST
    else
      post_attachments = videos[video_index...(video_index + MAX_VIDEOS_PER_POST)] # Send videos next
      video_index += MAX_VIDEOS_PER_POST if post_attachments&.any? == true
    end

    # EXIT CONDITION - we have no more attachments and there aren't any text
    # parts left to send out either.
    #
    break if post_attachments&.any? != true && raw_post_text.nil?

    puts "TEXT:"
    puts actual_post_text
    puts "ATTACHMENTS:"
    puts post_attachments&.any? == true ? post_attachments.inspect : "- NONE"

    embed    = nil
    is_video = false # Loop below might change this to 'true'

    post_attachments.each do | attachment_pathname |
      dimensions, mime_type = if File.extname(attachment_pathname).downcase == '.jpg'
        [FastImage.size(attachment_pathname), 'image/jpeg']
      else
        [VideoDimensions.dimensions(attachment_pathname), 'video/mp4']
      end

      is_video = mime_type.start_with?('video')

      unless is_video
        image_size    = File.size(attachment_pathname)
        quality_guess = 99

        if image_size > MAX_PHOTO_BYTES
          puts "Image size of #{image_size} exceeds #{MAX_PHOTO_BYTES}, so re-encoding JPEG..."

          loop do
            puts "Trying quality #{quality_guess}..."

            # Use ::open to refer to the original but not modify it, vs ::new,
            # which modifies the image in-place.
            #
            image = MiniMagick::Image.open(attachment_pathname)
            image.quality(quality_guess)

            image_tempfile.unlink() unless image_tempfile.nil?
            image_tempfile = Tempfile.new('instablue') # An 'ensure' block tidies this later
            image.write(image_tempfile)
            image_tempfile.close() # Close but don't delete

            image_size = image_tempfile.size

            if image_size > MAX_PHOTO_BYTES
              quality_guess -= 2
            else
              puts "...successful at file size #{image_size}"
              attachment_pathname = image_tempfile.path
              break # NOTE EARLY LOOP EXIT
            end
          end
        end
      end

      if USE_REAL_API_CALLS
        response = BSKY_CLIENT.post_request(
          'com.atproto.repo.uploadBlob',
          File.read(attachment_pathname).force_encoding('ASCII-8BIT'),
          headers: { 'Content-Type' => mime_type }
        )

        # Only one video is supported in the API at a low level, so this will
        # keep overwriting until updated, regardless of MAX_VIDEOS_PER_POST.
        #
        if is_video
          embed = {
            '$type':     'app.bsky.embed.video',
            video:       response['blob'],
            aspectRation: {
              width:  dimensions.first,
              height: dimensions.last
            }
          }
        else
          embed ||= {
            '$type': 'app.bsky.embed.images',
            images:  []
          }

          embed[:images] << {
            alt:         File.basename(attachment_pathname),
            image:       response['blob'],
            aspectRatio: {
              width:  dimensions.first,
              height: dimensions.last
            }
          }
        end
      end
    end

    if USE_REAL_API_CALLS
      record_body = {
        text:      actual_post_text,
        createdAt: shifted_date_time.iso8601,
        langs:     ['en']
      }

      record_body['embed'] = embed unless embed.nil?

      unless root_post_uri.nil?
        record_body['reply'] = {
          root: {
            uri: root_post_uri,
            cid: root_post_cid
          },
          parent: {
            uri: root_post_uri,
            cid: root_post_cid
          }
        }
      end

      response = BSKY_CLIENT.post_request(
        'com.atproto.repo.createRecord',
        {
          repo:       BSKY_CLIENT.user.did,
          collection: 'app.bsky.feed.post',
          record:     record_body
        }
      )

      if root_post_uri.nil?
        root_post_uri = response['uri']
        root_post_cid = response['cid']

        # Date, HTTPS URL, snippet, AT URL
        #
        csv_string << CSV.generate_line([
          shifted_date_time.iso8601,
          at_to_https(root_post_uri),
          raw_post_text.sub(COPY_TEXT_AS_PREFIX, '').strip[...80],
          root_post_uri
        ])

        begin
          File.write(CSV_RESULTS_FILE, csv_string)
        rescue => e
          puts "CSV write error - ignoring..."
          puts e.inspect
        end

        puts "ROOT POST DETTAILS:"
        puts at_to_https(root_post_uri)
        puts root_post_uri
        puts root_post_cid
      end
    end

    text_index += 1
  end

  posts_finished << post_date_time.iso8601
  File.write(FINISHED_FILE, YAML.dump(posts_finished))

  if SLEEP_BETWEEN_POSTS > 0
    puts "(Sleep #{SLEEP_BETWEEN_POSTS}s)"
    puts
    sleep SLEEP_BETWEEN_POSTS
  end

  puts "="*80
  puts

ensure
  image_tempfile.unlink() unless image_tempfile.nil?
  image_tempfile = nil
end

puts "*" * 80
puts "Root post creation count: #{posts_finished.size}"
puts "Writing final results CSV file..."

begin
  File.write(CSV_RESULTS_FILE, csv_string)
rescue => e
  puts "CSV write error!"
  puts e.inspect
  puts csv_string
end

puts "*" * 80
