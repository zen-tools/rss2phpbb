Script to parse news articles from RSS feed and post it to phpbb 3.1.x forum

```
$ ./rss_reposter.pl --help
Usage: ./rss_reposter.pl [ARGS]

Mandatory arguments:

    --forum-url='http://linuxhub.ru'
    --forum-login='TestUser'
    --forum-passw='TestPassword'
    --forum-post-id=7

Optional arguments:

    --forum-post-subj='News Digest # DIGEST_NUM'
    --forum-post-label='[Read More]'
    --save-file='/tmp/rss.save'
    --rss-url='http://www.opennet.ru/opennews/opennews_all_noadv.rss'
    --debug

```
