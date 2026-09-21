#!/bin/bash

### Script for downloading albums from Youtube Music ##########
### Usage: ./yt-music-album-download.sh <youtube music url> ###

# - Converts to MP3 from the best quality audio feed
# - Adds track number, album, artist, title, and release year into id3 tags
# - Adds album art embedded thumbnails

output_dir="."

while getopts "o:" opt; do
        case $opt in
                o) output_dir="$OPTARG" ;;
                *) echo "Usage: $0 [-o output_directory] <youtube music url>"; exit 1 ;;
        esac
done

shift $((OPTIND - 1))

if [ -z "$1" ]; then
        echo "Usage: $0 [-o output_directory] <youtube music url>"
        exit 1
fi

echo "Retrieving album information..."
# Downloading the json data of the first track only
jsondata=`yt-dlp -j --playlist-items 1 "$1"`

# Grabbing the "release_year" and "release_date" and comparing which is lowest integer.
# Sometimes Youtube Music doesn't even populate the "release_date" field, but when it does we need to compare it to "release_year"
# If both the "release_date" and "release_year" exist, check which one is the lower integer, and that should be the actual album release year.
jq_release_year_1=`echo "$jsondata" | jq -r '.release_year'`
jq_release_date=`echo "$jsondata" | jq -r '.release_date'`
if [ "$jq_release_date" != 'null' ]; then
        jq_release_year_2=${jq_release_date::-4};
        year=$((jq_release_year_1<jq_release_year_2?jq_release_year_1:jq_release_year_2));
else
        year=$jq_release_year_1;
fi

# Grabbing the artist then removing any additional information after the first comma. Some artists put every band memember into the artist field.
jq_artist=`echo "$jsondata" | jq -r '.artist'`
artist=${jq_artist%%,*}

# Grabbing the album title for the MusicBrainz lookup. If it's a single, use the track title.
jq_album=`echo "$jsondata" | jq -r '.album'`
jq_title=`echo "$jsondata" | jq -r '.track // .title'`

if [ "$jq_album" != 'null' ] && [ -n "$jq_album" ]; then
        mb_release="$jq_album"
else
        mb_release="$jq_title"
fi

# Looking up the highest-voted normalized genre from MusicBrainz.
MB_USER_AGENT="query/1.0"

mb_search=`curl -fsSG \
        -A "$MB_USER_AGENT" \
        "https://musicbrainz.org/ws/2/release-group/" \
        --data-urlencode "query=artist:\"$artist\" AND release:\"$mb_release\"" \
        --data-urlencode "fmt=json" \
        --data-urlencode "limit=1" 2>/dev/null`

mbid=`echo "$mb_search" | jq -r '.["release-groups"][0].id // empty'`
mb_score=`echo "$mb_search" | jq -r '.["release-groups"][0].score // 0'`

genre=""

if [ -n "$mbid" ] && [ "$mb_score" -ge 80 ]; then
        sleep 1

        mb_data=`curl -fsS \
                -A "$MB_USER_AGENT" \
                "https://musicbrainz.org/ws/2/release-group/$mbid?inc=genres&fmt=json" 2>/dev/null`

        genre=`echo "$mb_data" | jq -r '
                [.genres[]? | select(.count > 0)]
                | if length > 0 then max_by(.count).name else empty end
        '`
fi

echo "Album information retrieved..."
echo "Genre: ${genre:-Unknown}"

# Pass to yt-dlp and begin download all the music!
yt-dlp  --ignore-errors \
        --format "(bestaudio[acodec^=opus]/bestaudio)/best" \
        --extract-audio \
        --audio-format mp3 \
        --audio-quality 0 \
        --parse-metadata "playlist_index:%(track_number)s" \
        --parse-metadata ":(?P<webpage_url>)" \
        --parse-metadata ":(?P<synopsis>)" \
        --parse-metadata ":(?P<description>)" \
        --add-metadata \
        --postprocessor-args "-metadata date='${year}' -metadata artist=\"${artist}\" -metadata album_artist=\"${artist}\" -metadata genre=\"${genre}\"" \
        --embed-thumbnail \
        --ppa "EmbedThumbnail+ffmpeg_o:-c:v mjpeg -vf crop=\"'if(gt(ih,iw),iw,ih)':'if(gt(iw,ih),ih,iw)'\"" \
        -o "$output_dir/$artist/%(album|Singles)s/%(playlist_index&{} - |)s%(title)s.%(ext)s" "$1"
