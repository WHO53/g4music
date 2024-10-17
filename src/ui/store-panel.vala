namespace G4 {

    namespace SearchMode {
        public const uint ANY = 0;
        public const uint ALBUM = 1;
        public const uint ARTIST = 2;
        public const uint TITLE = 3;
    }

    public const string[] SORT_MODE_ICONS = {
        "media-optical-cd-audio-symbolic",  // ALBUM
        "system-users-symbolic",            // ARTIST
        "avatar-default-symbolic",          // ARTIST_ALBUM
        "folder-music-symbolic",            // TITLE
        "document-open-recent-symbolic",    // RECENT
        "media-playlist-shuffle-symbolic",  // SHUFFLE
    };

    namespace StackFlags {
        public const uint FIRST = 1;
        public const uint ARTISTS = 1;
        public const uint ALBUMS = 2;
        public const uint PLAYLISTS = 3;
        public const uint LAST = 4;
    }

    [GtkTemplate (ui = "/com/github/neithern/g4music/gtk/store-panel.ui")]
    public class StorePanel : Gtk.Box, SizeWatcher {
        [GtkChild]
        public unowned Gtk.HeaderBar header_bar;
        [GtkChild]
        public unowned Gtk.Label indicator;
        [GtkChild]
        private unowned Gtk.MenuButton sort_btn;
        [GtkChild]
        private unowned Gtk.ToggleButton search_btn;
        [GtkChild]
        private unowned Gtk.SearchBar search_bar;
        [GtkChild]
        private unowned Gtk.SearchEntry search_entry;
        [GtkChild]
        private unowned Gtk.Stack stack_view;

        private Stack _album_stack = new Stack ();
        private Stack _artist_stack = new Stack ();
        private Stack _playlist_stack = new Stack ();
        private MiniBar _mini_bar = new MiniBar ();
        private Gtk.StackSwitcher _switcher_top = new Gtk.StackSwitcher ();
        private Gtk.StackSwitcher _switcher_btm = new Gtk.StackSwitcher ();

        private Application _app;
        private MusicList _album_list;
        private MusicList _artist_list;
        private MusicList _current_list;
        private MainMusicList _main_list;
        private MusicList _playlist_list;
        private MusicLibrary _library;
        private string? _library_uri = null;
        private Gdk.Paintable _loading_paintable;
        private uint _search_mode = SearchMode.ANY;
        private string _search_text = "";
        private bool _size_allocated = false;
        private uint _sort_mode = -1;
        private bool _updating_store = false;

        public StorePanel (Application app, Window win, Leaflet leaflet) {
            _app = app;
            _library = app.loader.library;
            margin_bottom = 6;

            var thumbnailer = app.thumbnailer;
            thumbnailer.pango_context = get_pango_context ();
            thumbnailer.scale_factor = this.scale_factor;
            _loading_paintable = thumbnailer.create_simple_text_paintable ("...", Thumbnailer.ICON_SIZE);

            search_btn.toggled.connect (on_search_btn_toggled);
            search_bar.key_capture_widget = win.content;
            search_entry.search_changed.connect (on_search_text_changed);

            _main_list = create_main_music_list ();
            _main_list.data_store = _app.music_queue;
            _app.current_list = _main_list.filter_model;
            _current_list = _main_list;
            stack_view.add_titled (_main_list, PageName.PLAYING, _("Playing")).icon_name = "user-home-symbolic";

            _artist_list = create_artist_list ();
            _artist_stack.add (_artist_list, PageName.ARTIST);
            _artist_stack.bind_property ("visible-child", this, "visible-child");
            stack_view.add_titled (_artist_stack.widget, PageName.ARTIST, _("Artists")).icon_name = "system-users-symbolic";

            _album_list = create_album_list ();
            _album_stack.add (_album_list, PageName.ALBUM);
            _album_stack.bind_property ("visible-child", this, "visible-child");
            stack_view.add_titled (_album_stack.widget, PageName.ALBUM, _("Albums")).icon_name = "drive-multidisk-symbolic";

            _playlist_list = create_playlist_list ();
            _playlist_stack.add (_playlist_list, PageName.PLAYLIST);
            _playlist_stack.bind_property ("visible-child", this, "visible-child");
            stack_view.add_titled (_playlist_stack.widget, PageName.PLAYLIST, _("Playlists")).icon_name = "view-list-symbolic";

            stack_view.transition_type = Gtk.StackTransitionType.SLIDE_LEFT_RIGHT;
            stack_view.bind_property ("visible-child", this, "visible-child");

            var mini_revealer = new Gtk.Revealer ();
            mini_revealer.child = _mini_bar;
            mini_revealer.transition_type = Gtk.RevealerTransitionType.SLIDE_UP;
            _mini_bar.activated.connect (leaflet.push);
            append (mini_revealer);
            leaflet.bind_property ("folded", mini_revealer, "reveal-child", BindingFlags.SYNC_CREATE);
            leaflet.bind_property ("folded", header_bar, "show-title-buttons");

            var top_revealer = new NarrowBar ();
            top_revealer.child = _switcher_top;
            _switcher_top.stack = stack_view;
            fix_switcher_style (_switcher_top);
            header_bar.pack_end (top_revealer);

            var btm_revealer = new Gtk.Revealer ();
            btm_revealer.child = _switcher_btm;
            btm_revealer.transition_type = Gtk.RevealerTransitionType.SLIDE_UP;
            append (btm_revealer);
            top_revealer.bind_property ("reveal", btm_revealer, "reveal-child", BindingFlags.INVERT_BOOLEAN);

            _switcher_btm.margin_top = 2;
            _switcher_btm.margin_start = 6;
            _switcher_btm.margin_end = 6;
            _switcher_btm.stack = stack_view;
            fix_switcher_style (_switcher_btm);

            app.index_changed.connect (on_index_changed);
            app.music_changed.connect (on_music_changed);
            app.music_library_changed.connect (on_music_library_changed);
            app.playlist_added.connect (on_playlist_added);
            app.thumbnail_changed.connect (on_thumbnail_changed);

            var settings = app.settings;
            settings.bind ("sort-mode", this, "sort-mode", SettingsBindFlags.DEFAULT);
            _library_uri = settings.get_string ("library-uri");
            initialize_library_page ();
        }

        public MusicList current_list {
            get {
                return _current_list;
            }
        }

        public bool modified {
            get {
                return _current_list.modified;
            }
            set {
                indicator.visible = _current_list.modified;
                root.action_set_enabled (ACTION_WIN + ACTION_SAVE_LIST, _current_list.modified);
            }
        }

        public uint sort_mode {
            get {
                return _sort_mode;
            }
            set {
                _sort_mode = value;
                if (value < SORT_MODE_ICONS.length)
                    sort_btn.set_icon_name (SORT_MODE_ICONS[value]);
                if (_main_list.get_height () > 0)
                    _main_list.create_factory ();
            }
        }

        public Gtk.Widget visible_child {
            set {
                if (_size_allocated) {
                    update_visible_stack ();
                }
                save_if_modified (true);

                if (value == stack_view.visible_child) {
                    var stack = get_current_stack ();
                    if (stack != null)
                        value = ((!)stack).visible_child;
                }
                if (value is MusicList) {
                    var list = _current_list = (MusicList) value;
                    on_music_changed (_app.current_music);

                    indicator.visible = _current_list.modified;
                    sort_btn.visible = _current_list == _main_list;
                    _search_mode = SearchMode.ANY;
                    on_search_btn_toggled ();

                    var scroll = !_overlayed_lists.remove (list);
                    run_idle_once (() => list.set_to_current_item (scroll), Priority.LOW);
                }
            }
        }

        public void first_allocated () {
            // Delay set model after the window size allocated to avoid showing slowly
            _size_allocated = true;
        }

        public void remove_from_list (Music music) {
            uint position = -1;
            if (_current_list.data_store.find (music, out position)) {
                _current_list.data_store.remove (position);
                _current_list.modified = true;
            }
        }

        public bool save_if_modified (bool prompt = true, VoidFunc? done = null) {
            if (_current_list.modified) {
                _current_list.save_if_modified.begin (prompt, (obj, res) => {
                    var ret = _current_list.save_if_modified.end (res);
                    if (ret != Result.FAILED) {
                        _current_list.modified = false;
                        if (done != null)
                            ((!)done) ();
                    }
                });
                return true;
            }
            return false;
        }

        public void set_mini_cover (Gdk.Paintable? cover) {
            _mini_bar.cover = cover;
        }

        public void size_to_change (int width, int height) {
        }

        public void start_search (string text, uint mode = SearchMode.ANY) {
            switch (mode) {
                case SearchMode.ALBUM:
                    stack_view.visible_child = _album_stack.widget;
                    break;
                case SearchMode.ARTIST:
                    stack_view.visible_child = _artist_stack.widget;
                    break;
                case SearchMode.TITLE:
                    stack_view.visible_child = _main_list;
                    break;
            }

#if GTK_4_10
            var delay = search_entry.search_delay;
            search_entry.search_delay = 0;
            run_idle_once (() => search_entry.search_delay = delay);
#endif
            search_entry.text = text;
            search_entry.select_region (0, -1);
            search_btn.active = true;
            _search_mode = mode;
        }

        public bool toggle_search () {
            search_btn.active = ! search_btn.active;
            return search_btn.active;
        }

        private void bind_music_list_properties (MusicList list, bool editable = false) {
            _app.settings.bind ("compact-playlist", list, "compact-list", SettingsBindFlags.DEFAULT);
            _app.settings.bind ("single-click-activate", list, "single-click-activate", SettingsBindFlags.DEFAULT);
            if (list.item_type != typeof (Music))
                _app.settings.bind ("grid-mode", list, "grid-mode", SettingsBindFlags.DEFAULT);
            if (editable)
                list.bind_property ("modified", this, "modified");
        }

        private MusicList create_album_list (Artist? artist = null) {
            var list = new MusicList (_app, typeof (Album), artist);
            list.item_activated.connect ((position, obj) => create_stack_page (artist, obj as Album));
            list.item_binded.connect ((item) => {
                var cell = (MusicWidget) item.child;
                var album = (Album) item.item;
                var album_artist = album.album_artist;
                var year = album.year;
                cell.music = album;
                cell.paintable = _loading_paintable;
                cell.title = album.album;
                var subtitle = year > 0 ? year.to_string () : " ";
                if (artist == null)
                    subtitle = (album_artist.length > 0 ? album_artist + " " : "") + subtitle;
                cell.subtitle = subtitle;
            });
            bind_music_list_properties (list);
            return list;
        }

        private MusicList create_artist_list () {
            var list = new MusicList (_app, typeof (Artist));
            list.item_activated.connect ((position, obj) => create_stack_page (obj as Artist));
            list.item_binded.connect ((item) => {
                var cell = (MusicWidget) item.child;
                var artist = (Artist) item.item;
                cell.cover.ratio = 0.5;
                cell.music = artist;
                cell.paintable = _loading_paintable;
                cell.title = artist.artist;
                cell.subtitle = "";
            });
            bind_music_list_properties (list);
            return list;
        }

        private MusicList create_music_list (Album album, bool from_artist = false) {
            var is_playlist = album is Playlist;
            var is_artist_playlist = is_playlist && from_artist;
            var sort_mode = is_artist_playlist ? SortMode.ALBUM : SortMode.TITLE;
            var list = new MusicList (_app, typeof (Music), album, is_playlist);
            list.item_activated.connect ((position, obj) => play_current_list ((int) position));
            list.item_binded.connect ((item) => {
                var entry = (MusicEntry) item.child;
                var music = (Music) item.item;
                entry.paintable = _loading_paintable;
                entry.set_titles (music, sort_mode);
            });
            bind_music_list_properties (list, is_playlist);
            return list;
        }

        private MainMusicList create_main_music_list () {
            var list = new MainMusicList (_app);
            list.item_activated.connect ((position, obj) => play_current_list ((int) position));
            list.item_binded.connect ((item) => {
                var entry = (MusicEntry) item.child;
                var music = (Music) item.item;
                entry.paintable = _loading_paintable;
                entry.set_titles (music, _sort_mode);
            });
            bind_music_list_properties (list, true);
            return list;
        }

        private MusicList create_playlist_list () {
            var list = new MusicList (_app, typeof (Playlist));
            list.item_activated.connect ((position, obj) => create_stack_page (null, obj as Playlist));
            list.item_binded.connect ((item) => {
                var cell = (MusicWidget) item.child;
                var playlist = (Playlist) item.item;
                cell.music = playlist;
                cell.paintable = _loading_paintable;
                cell.title = playlist.title;
            });
            bind_music_list_properties (list);
            return list;
        }

        private Gtk.Box create_title_box (string icon_name, string title, Playlist? plist) {
            var label = new Gtk.Label (title);
            label.ellipsize = Pango.EllipsizeMode.MIDDLE;
            var icon = new Gtk.Image.from_icon_name (icon_name);
            var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
            box.append (icon);
            box.append (label);
            if (plist != null && ((!)plist).list_uri.length > 0) {
                var playlist = (!)plist;
                var entry = new Gtk.Entry ();
                entry.max_width_chars = 1024;
                entry.text = title;
                entry.visible = false;
                entry.activate.connect (() => {
                    entry.visible = false;
                    label.visible = true;
                    var text = entry.text;
                    if (text.length > 0 && text != playlist.title) {
                        _app.rename_playlist_async.begin (playlist, text, (obj, res) => {
                            var ret = _app.rename_playlist_async.end (res);
                            if (ret)
                                label.label = playlist.title;
                        });
                    }
                });
                var event = new Gtk.EventControllerKey ();
                event.key_pressed.connect ((keyval, keycode, state) => {
                    if (keyval == Gdk.Key.Escape) {
                        entry.visible = false;
                        label.visible = true;
                        return true;
                    }
                    return false;
                });
                entry.add_controller (event);
                make_widget_clickable (label).released.connect (() => {
                    entry.text = label.label;
                    entry.visible = true;
                    entry.grab_focus ();
                    label.visible = false;
                });
                box.append (entry);
            }
            return box;
        }

        private GenericSet<unowned MusicList> _overlayed_lists = new GenericSet<unowned MusicList> (direct_hash, direct_equal);

        private void create_stack_page (Artist? artist, Album? album = null) {
            var album_mode = album != null;
            var artist_mode = artist != null;
            var playlist_mode = album is Playlist;
            var mlist = album_mode ? create_music_list ((!)album, artist_mode) : create_album_list (artist);
            mlist.update_store ();

            var icon_name = (album is Playlist) ? "emblem-documents-symbolic" : (album_mode ? "media-optical-cd-audio-symbolic" : "avatar-default-symbolic");
            var title = (album_mode ? album?.title : artist?.title) ?? "";
            var title_box = create_title_box (icon_name, title, album as Playlist);
            title_box.halign = Gtk.Align.CENTER;
            title_box.hexpand = true;

            var header = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
            header.hexpand = true;
            header.add_css_class ("flat");
            header.add_css_class ("toolbar");
            header.append (title_box);
            mlist.prepend (header);

            var stack = artist_mode ? _artist_stack : playlist_mode ? _playlist_stack : _album_stack;
            var back_btn = new Gtk.Button.from_icon_name ("go-previous-symbolic");
            back_btn.tooltip_text = _("Back");
            back_btn.clicked.connect (stack.pop);
            header.prepend (back_btn);

            var key_length = album?.album_key?.length ?? 0;
            if (artist_mode || key_length > 0) {
                var split_btn = new Adw.SplitButton ();
                split_btn.icon_name = "media-playback-start-symbolic";
                split_btn.tooltip_text = _("Play");
                split_btn.clicked.connect (() => {
                    var uri = build_library_uri (artist, album);
                    open_page (uri, true);
                });
                if (artist != null)
                    split_btn.menu_model = (album == null || album is Playlist) ? create_menu_for_artist ((!)artist) : create_menu_for_album ((!)album);
                else if (album != null)
                    split_btn.menu_model = create_menu_for_album ((!)album);
                (split_btn.menu_model as Menu)?.remove (0); // Play
                header.append (split_btn);
            }

            if (stack.animate_transitions && stack.visible_child == _current_list)
                _overlayed_lists.add (_current_list);
            stack.add (mlist, album_mode ? album?.album_key : artist?.artist_name);
        }

        private Stack? get_current_stack () {
            var child = stack_view.visible_child;
            if (_artist_stack.widget == child)
                return _artist_stack;
            else if (_album_stack.widget == child)
                return _album_stack;
            else if (_playlist_stack.widget == child)
                return _playlist_stack;
            return null;
        }

        private void initialize_library_page () {
            if (_library_uri != null) {
                open_page ((!)_library_uri);
                if (!_library.empty) {
                    _library_uri = null;
                    if (_current_list.playable) {
                        _app.current_list = _current_list.filter_model;
                        _album_key_of_list = _current_list.music_node?.album_key;
                    }
                }
            }
        }

        private void save_playing_page () {
            var paths = new GenericArray<string> (4);
            var stack = get_current_stack ();
            if (stack != null) {
                ((!)stack).get_visible_names (paths);
            } else {
                paths.add (stack_view.get_visible_child_name () ?? "");
            }
            var uri = build_library_uri_from_sa (paths.data);
            _app.settings.set_string ("library-uri", uri);
            _album_key_of_list = _current_list.music_node?.album_key;
        }

        public void open_page (string uri, bool play_now = false, bool shuffle = false) {
            string? ar = null, al = null, pl = null, page = null;
            if (parse_library_uri (uri, out ar, out al, out pl, out page)) {
                stack_view.transition_type = Gtk.StackTransitionType.NONE;
                stack_view.visible_child_name = (!)page;
                stack_view.transition_type = Gtk.StackTransitionType.SLIDE_LEFT_RIGHT;
                var stk = get_current_stack ();
                if (stk != null) {
                    var stack = (!)stk;
                    stack.animate_transitions = false;
                    Artist? artist = null;
                    Album? album = null;
                    if (ar != null) {
                        artist = _library.artists[(!)ar];
                        if (artist is Artist) {
                            if (stack.get_child_by_name (((!)artist).artist) == null) {
                                create_stack_page (artist);
                            }
                            if (al != null) {
                                if (((!)al).length > 0)
                                    album = ((!)artist)[(!)al];
                                else
                                    album = ((!)artist).to_playlist ();
                            }
                        }
                    } else if (al != null) {
                        album = _library.albums[(!)al];
                    } else if (pl != null) {
                        album = _library.playlists[(!)pl];
                    }
                    if (album != null && stack.get_child_by_name (((!)album).album_key) == null) {
                        if ((stack.visible_child as MusicList)?.playable ?? false)
                            stack.pop ();
                        create_stack_page (artist, album);
                    }
                    ((!)stack).animate_transitions = true;
                    if (album != null) {
                        if (shuffle) {
                            sort_music_store (_current_list.data_store, SortMode.SHUFFLE);
                        } else {
                            ((!)album).overwrite_to (_current_list.data_store);
                        }
                        if (play_now) {
                            play_current_list ();
                        }
                    }
                }
            }
        }

        public int open_next_playable_page () {
            var stk = get_current_stack ();
            if (stk == null) {
                _app.current_list = _main_list.filter_model;
            } else if (!_updating_store) {
                var stack = (!)stk;
                if (_app.current_list == _current_list.filter_model) {
                    stack.animate_transitions = false;
                    stack.pop ();
                    stack.animate_transitions = true;
                }
                var index = _current_list.set_to_current_item (false);
                if (index >= (int) _current_list.visible_count - 1) {
                    stack.animate_transitions = false;
                    stack.pop ();
                    stack.animate_transitions = true;
                    index = _current_list.set_to_current_item (false);
                }
                _current_list.activate_item (index < (int) _current_list.visible_count - 1 ? index + 1 : 0);
                if (!_current_list.playable) {
                    _current_list.activate_item (0);
                }
                _app.current_list = _current_list.filter_model;
            }
            save_playing_page ();

            var count = (int) _app.current_list.get_n_items ();
            var index = _app.current_item + 1;
            return index < count ? index : 0;
        }

        private void on_index_changed (int index, uint size) {
            if (_current_list.filter_model == _app.current_list && _current_list.playable
                    && _current_list.dropping_item == -1 && !_current_list.multi_selection) {
                _current_list.scroll_to_item (index);
            }
        }

        private void on_music_changed (Music? music) {
            if (_current_list.playable) {
                _current_list.current_node = music;
            } else if (_current_list.item_type == typeof (Artist)) {
                var artist_name = music?.artist_name ?? "";
                _current_list.current_node = _library.artists[artist_name];
            } else if (_current_list.item_type == typeof (Album)) {
                var album = music?.album_key ?? "";
                var artist = _current_list.music_node as Artist;
                _current_list.current_node = artist != null ? ((!)artist)[album] : _library.albums[album];
            } else if (_current_list.item_type == typeof (Playlist)) {
                if (_album_key_of_list != null)
                    _current_list.current_node = _library.playlists[(!)_album_key_of_list];
            }
            _mini_bar.title = music?.title ?? "";
        }

        private Gtk.Bitset _changing_stacks = new Gtk.Bitset.empty ();

        private void on_music_library_changed (bool external) {
            _main_list.modified |= _app.list_modified;
            if (external) {
                _changing_stacks.add_range (StackFlags.FIRST, StackFlags.LAST - StackFlags.FIRST);
                if (_size_allocated) {
                    update_visible_stack ();
                    initialize_library_page ();
                }
            }
        }

        private void on_playlist_added (Playlist playlist) {
            var list = _playlist_stack.visible_child as MusicList;
            var node = list?.music_node;
            if (strcmp (playlist.list_uri, (node as Playlist)?.list_uri) == 0) {
                playlist.overwrite_to (((!)list).data_store);
            }

            var arr = new GenericArray<Music> (1);
            arr.add (playlist);
            uint position = -1;
            merge_items_to_store (_playlist_list.data_store, arr, ref position);
            sort_music_store (_playlist_list.data_store, SortMode.TITLE);
        }

        private void on_search_btn_toggled () {
            if (search_btn.active) {
                search_entry.grab_focus ();
            }
            on_search_text_changed ();
        }

        private bool on_search_match (Object obj) {
            unowned var music = (Music) obj;
            unowned var text = _search_text;
            switch (_search_mode) {
                case SearchMode.ALBUM:
                    return text.match_string (music.album, true);
                case SearchMode.ARTIST:
                    return text.match_string (music.artist, true)
                        || text.match_string (music.album_artist, true)
                        || ((music as Artist)?.find_by_partial_artist (text) != null);
                case SearchMode.TITLE:
                    return text.match_string (music.title, true);
                default:
                    return text.match_string (music.album, true)
                        || text.match_string (music.album_artist, true)
                        || text.match_string (music.artist, true)
                        || text.match_string (music.title, true);
            }
        }

        private void on_search_text_changed () {
            _search_text = search_entry.text;
            parse_search_mode (ref _search_text, ref _search_mode);
            if (_current_list == _album_list) {
                _search_mode = SearchMode.ALBUM;
            } else if (_current_list == _artist_list) {
                _search_mode = SearchMode.ARTIST;
            }

            var model = _current_list.filter_model;
            if (search_btn.active && model.get_filter () == null) {
                model.set_filter (new Gtk.CustomFilter (on_search_match));
            } else if (!search_btn.active && model.get_filter () != null) {
                model.set_filter (null);
            }
            model.get_filter ()?.changed (Gtk.FilterChange.DIFFERENT);
        }

        private void on_thumbnail_changed (Music music, Gdk.Paintable paintable) {
            _current_list.update_item_cover (music, paintable);
        }

        private string? _album_key_of_list = null;

        private void play_current_list (int index = 0) {
            if (_current_list.playable && _app.current_list != _current_list.filter_model) {
                _app.current_list = _current_list.filter_model;
                save_playing_page ();
            }
            _app.current_item = index;
        }

        private void update_stack_pages (Stack stack) {
            var animate = stack.animate_transitions;
            stack.animate_transitions = false;
            var children = stack.get_children ();
            for (var i = children.length - 1; i >= 0; i--) {
                var mlist = (MusicList) children[i];
                if (mlist.music_node != null && mlist.update_store () == 0)
                    stack.pop ();
            }
            stack.animate_transitions = animate;
        }

        private void update_visible_stack () {
            _updating_store = true;
            var child = stack_view.visible_child;
            if (child == _album_stack.widget && _changing_stacks.remove (StackFlags.ALBUMS)) {
                update_stack_pages (_album_stack);
                _library.overwrite_albums_to (_album_list.data_store);
            } else if (child == _artist_stack.widget && _changing_stacks.remove (StackFlags.ARTISTS)) {
                update_stack_pages (_artist_stack);
                _library.overwrite_artists_to (_artist_list.data_store);
            } else if (child == _playlist_stack.widget && _changing_stacks.remove (StackFlags.PLAYLISTS)) {
                update_stack_pages (_playlist_stack);
                var text = _("No playlist found in %s").printf (get_display_name (_app.music_folder));
                _library.overwrite_playlists_to (_playlist_list.data_store);
                _playlist_list.set_empty_text (text);
            }
            _updating_store = false;
        }
    }

    public void fix_switcher_style (Gtk.StackSwitcher switcher) {
        var layout = switcher.get_layout_manager () as Gtk.BoxLayout;
        layout?.set_spacing (4);
        switcher.remove_css_class ("linked");
        for (var child = switcher.get_first_child (); child != null; child = child?.get_next_sibling ()) {
            child?.add_css_class ("flat");
            ((!)child).width_request = 48;
        }
    }

    public void parse_search_mode (ref string text, ref uint mode) {
        if (text.ascii_ncasecmp ("album:", 6) == 0) {
            mode = SearchMode.ALBUM;
            text = text.substring (6);
        } else if (text.ascii_ncasecmp ("artist:", 7) == 0) {
            mode = SearchMode.ARTIST;
            text = text.substring (7);
        } else if (text.ascii_ncasecmp ("title:", 6) == 0) {
            mode = SearchMode.TITLE;
            text = text.substring (6);
        }
    }
}
