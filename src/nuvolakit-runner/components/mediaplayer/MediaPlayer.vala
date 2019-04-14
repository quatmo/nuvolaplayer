/*
 * Copyright 2014-2019 Jiří Janoušek <janousek.jiri@gmail.com>
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice, this
 *    list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
 * ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

public class Nuvola.MediaPlayer: GLib.Object, Nuvola.MediaPlayerModel {
    public string? title {get; set; default = null;}
    public string? artist {get; set; default = null;}
    public string? album {get; set; default = null;}
    public double rating {get; set; default = 0.0;}
    public string? state {get; set; default = null;}
    public PlaybackRepeat repeat {get; set; default = PlaybackRepeat.NONE;}
    public string? artwork_location {get; set; default = null;}
    public string? artwork_file {get; set; default = null;}
    public int64 track_length {get; set; default = 0;}
    public int64 track_position {get; set; default = 0;}
    public double volume {get; set; default = 1.0;}
    public bool shuffle {get; set; default = false;}
    public bool can_go_next {get; set; default = false;}
    public bool can_go_previous {get; set; default = false;}
    public bool can_play {get; set; default = false;}
    public bool can_pause {get; set; default = false;}
    public bool can_stop {get; set; default = false;}
    public bool can_rate {get; set; default = false;}
    public bool can_seek {get; set; default = false;}
    public bool can_change_volume {get; set; default = false;}
    public SList<string> playback_actions {get; owned set;}
    private Drtgtk.Actions actions;

    public MediaPlayer(Drtgtk.Actions actions) {
        this.actions = actions;
        bind_action("repeat");
        bind_action("shuffle");
        actions.action_added.connect(on_action_added);
    }

    ~MediaPlayer() {
        actions.action_added.disconnect(on_action_added);
        foreach (unowned string name in new (unowned string)[] {"repeat", "shuffle"}) {
            Drtgtk.Action? action = actions.get_action(name);
            if (action != null) {
                action.notify["state"].disconnect(on_action_changed);
            }
        }
    }

    private void on_action_added(Drtgtk.Action action) {
        if (action.name == "repeat" || action.name == "shuffle") {
            bind_action(action.name);
        }
    }

    private bool bind_action(string name) {
        Drtgtk.Action? action = actions.get_action(name);
        if (action == null) {
            return false;
        }
        action.notify["state"].connect_after(on_action_changed);
        update_action(action);
        return true;
    }

    protected void handle_set_track_info(
        string? title, string? artist, string? album, string? state, string? artwork_location, string? artwork_file,
        double rating, int64 length) {
        this.title = title;
        this.artist = artist;
        this.album = album;
        this.rating = rating;
        this.state = state;
        this.artwork_location = artwork_location;
        this.artwork_file = artwork_file;
        this.track_length = length;
    }

    public void play() {
        activate_action("play");
    }

    public void pause() {
        activate_action("pause");
    }

    public void toggle_play() {
        activate_action("toggle-play");
    }

    public void stop() {
        activate_action("stop");
    }

    public void prev_song() {
        activate_action("prev-song");
    }

    public void next_song() {
        activate_action("next-song");
    }

    public void seek(int64 position) {
        activate_action("seek", position);
    }

    public void change_volume(double volume) {
        activate_action("change-volume", volume);
    }

    public void change_repeat(PlaybackRepeat repeat) {
        activate_action("repeat", new Variant.double((double) repeat));
    }

    public void change_shuffle(bool shuffle) {
        activate_action("shuffle", shuffle);
    }

    private void update_action(Drtgtk.Action action) {
        switch (action.name) {
        case "repeat":
            repeat = (PlaybackRepeat) (double) action.state;
            break;
        case "shuffle":
            shuffle = action.state.get_boolean();
            break;
        }
    }

    private void activate_action(string name, Variant? parameter=null) {
        if (!actions.activate_action(name, parameter)) {
            critical("Failed to activate action '%s'.", name);
        }
    }

    private void on_action_changed(GLib.Object emitter, ParamSpec parameter) {
        var action = (Drtgtk.Action) emitter;
        update_action(action);
    }
}
