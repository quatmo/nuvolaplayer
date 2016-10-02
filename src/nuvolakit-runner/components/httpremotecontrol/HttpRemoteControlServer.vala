/*
 * Copyright 2016 Jiří Janoušek <janousek.jiri@gmail.com>
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

#if EXPERIMENTAL
namespace Nuvola.HttpRemoteControl
{

public const string CAPABILITY_NAME = "httpcontrol";

public class Server: Soup.Server
{
	private const string APP_REGISTERED = "/nuvola/httpremotecontrol/app-registered";
	private const string APP_UNREGISTERED = "/nuvola/httpremotecontrol/app-unregistered";
	private MasterBus bus;
	private MasterController app;
	private HashTable<string, AppRunner> app_runners;
	private unowned Queue<AppRunner> app_runners_order;
	private GenericSet<string> registered_runners;
	private WebAppRegistry web_app_registry;
	private bool running = false;
	private File[] www_roots;
	private Channel eio_channel;
	private HashTable<string, Diorite.SingleList<Subscription>> subscribers;
	
	public Server(
		MasterController app, MasterBus bus,
		HashTable<string, AppRunner> app_runners, Queue<AppRunner> app_runners_order,
		WebAppRegistry web_app_registry, File[] www_roots)
	{
		this.app = app;
		this.bus = bus;
		this.app_runners = app_runners;
		this.app_runners_order = app_runners_order;
		this.web_app_registry = web_app_registry;
		this.www_roots = www_roots;
		registered_runners = new GenericSet<string>(str_hash, str_equal);
		subscribers = new HashTable<string, Diorite.SingleList<Subscription>>(str_hash, str_equal);
		bus.router.add_method("/nuvola/httpremotecontrol/register", Drt.ApiFlags.PRIVATE|Drt.ApiFlags.WRITABLE,
			null, handle_register, {
			new Drt.StringParam("id", true, false)
		});
		bus.router.add_method("/nuvola/httpremotecontrol/unregister", Drt.ApiFlags.PRIVATE|Drt.ApiFlags.WRITABLE,
			null, handle_unregister, {
			new Drt.StringParam("id", true, false)
		});
		bus.router.add_notification(APP_REGISTERED, Drt.ApiFlags.SUBSCRIBE|Drt.ApiFlags.WRITABLE, null);
		bus.router.add_notification(APP_UNREGISTERED, Drt.ApiFlags.SUBSCRIBE|Drt.ApiFlags.WRITABLE, null);
		app.runner_exited.connect(on_runner_exited);
		bus.router.notification.connect(on_master_notification);
		var eio_server = new Engineio.Server(this, "/nuvola.io/");
		eio_channel = new Channel(eio_server, this);
	}
	
	~Server()
	{
		app.runner_exited.disconnect(on_runner_exited);
		bus.router.notification.disconnect(on_master_notification);
	}
	
	public void start()
	{
		var port = 8089;
		message("Start HttpRemoteControlServer at port %d", port);
		add_handler("/", default_handler);
		try
		{
			listen_all(port, 0);
			running = true;
		}
		catch (GLib.Error e)
		{
			critical("Cannot start HttpRemoteControlServer at port %d: %s", port, e.message);
		}
	}
	
	public void stop()
	{
		message("Stop HttpRemoteControlServer");
		disconnect();
		remove_handler("/");
		running = false;
	}
	
	private void register_app(string app_id)
	{
		message("HttpRemoteControlServer: Register app id: %s", app_id);
		registered_runners.add(app_id);
		var app = app_runners[app_id];
		app.add_capatibility(CAPABILITY_NAME);
		app.notification.connect(on_app_notification);
		if (!running)
			start();
		bus.router.emit(APP_REGISTERED, app_id, app_id);
	}
	
	private bool unregister_app(string app_id)
	{
		message("HttpRemoteControlServer: unregister app id: %s", app_id);
		var app = app_runners[app_id];
		if (app != null)
		{
			app.remove_capatibility(CAPABILITY_NAME);
			app.notification.disconnect(on_app_notification);
		}
		var result = registered_runners.remove(app_id);
		bus.router.emit(APP_UNREGISTERED, app_id, app_id);
		if (running && registered_runners.length == 0)
			stop();
		return result;
	}
	
	private void on_runner_exited(AppRunner runner)
	{
		unregister_app(runner.app_id);
	}
	
	private static void default_handler(
		Soup.Server server, Soup.Message msg, string path, GLib.HashTable? query, Soup.ClientContext client)
	{
		var self = server as Server;
		assert(self != null);
		self.handle_request(new RequestContext(server, msg, path, query, client));
	}
	
	public async Variant? handle_eio_request(Engineio.Socket socket, Engineio.MessageType type, string path, Variant? params) throws GLib.Error
	{
		if (path.has_prefix("/app/"))
		{
			var app_path = path.substring(5);
			string app_id;
			var slash_pos = app_path.index_of_char('/');
			if (slash_pos <= 0)
			{
				app_id = app_path;
				app_path = "";
			}
			else
			{
				app_id = app_path.substring(0, slash_pos);
				app_path = app_path.substring(slash_pos);
			}
			if (!(app_id in registered_runners))
			{
				throw new ChannelError.APP_NOT_FOUND("App with id '%s' doesn't exist or HTTP interface is not enabled.", app_id);
			}
			
			if (type == Engineio.MessageType.SUBSCRIBE)
			{
				bool subscribe = true;
				string? detail = null;
				var abs_path = "/app/%s/nuvola%s".printf(app_id, path);
				Drt.ApiNotification.parse_dict_params(abs_path, params, out subscribe, out detail);
				yield this.subscribe(app_id, app_path, subscribe, detail, socket);
				return null;
			}
			
			var app = app_runners[app_id];
			return yield app.call_full("/nuvola" + app_path, false, "rw", "dict", params);
		}
		if (path.has_prefix("/master/"))
		{
			var master_path = path.substring(7);
			if (type == Engineio.MessageType.SUBSCRIBE)
			{
				bool subscribe = true;
				string? detail = null;
				var abs_path = "/master/nuvola%s".printf(master_path);
				Drt.ApiNotification.parse_dict_params(abs_path, params, out subscribe, out detail);
				yield this.subscribe(null, master_path, subscribe, detail, socket);
				return null;
			}
			
			return bus.call_local_sync_full("/nuvola" + master_path, false, "rw", "dict", params);
		}
		throw new ChannelError.INVALID_REQUEST("Request '%s' is invalid.", path);
	}
	
	protected void handle_request(RequestContext request)
	{
		var path = request.path;
		if (path == "/+api/app" || path == "/+api/app/")
		{
			request.respond_json(200, list_apps());
			return;
		}
		if (path.has_prefix("/+api/app/"))
		{
			var app_path = path.substring(10);
			string app_id;
			var slash_pos = app_path.index_of_char('/');
			if (slash_pos <= 0)
			{
				app_id = app_path;
				app_path = "";
			}
			else
			{
				app_id = app_path.substring(0, slash_pos);
				app_path = app_path.substring(slash_pos + 1);
			}
			if (!(app_id in registered_runners))
			{
				request.respond_not_found();
			}
			else
			{
				var app_request = new AppRequest.from_request_context(app_path, request);
				message("App-specific request %s: %s => %s", app_id, app_path, app_request.to_string());
				try
				{
					var data = send_app_request(app_id, app_request);
					request.respond_json(200, data);
				}
				catch (GLib.Error e)
				{
					var builder = new VariantBuilder(new VariantType("a{sv}"));
					builder.add("{sv}", "error", new Variant.int32(e.code));
					builder.add("{sv}", "message", new Variant.string(e.message));
					builder.add("{sv}", "quark", new Variant.string(e.domain.to_string()));
					request.respond_json(400, Json.gvariant_serialize(builder.end()));
				}
			}
			return;
		}
		else if (path.has_prefix("/+api/"))
		{
			try
			{
				var data = send_local_request(path.substring(6), request);
				request.respond_json(200, data);
			}
			catch (GLib.Error e)
			{
				var builder = new VariantBuilder(new VariantType("a{sv}"));
				builder.add("{sv}", "error", new Variant.int32(e.code));
				builder.add("{sv}", "message", new Variant.string(e.message));
				builder.add("{sv}", "quark", new Variant.string(e.domain.to_string()));
				request.respond_json(400, Json.gvariant_serialize(builder.end()));
			}
			return;
		}
		serve_static(request);
	}
	
	public async void subscribe(string? app_id, string path, bool subscribe, string? detail, Engineio.Socket socket) throws GLib.Error
	{
		var abs_path = app_id != null ? "/app/%s/nuvola%s".printf(app_id, path) : "/master/nuvola%s".printf(path);
		var subscribers = this.subscribers[abs_path];
		if (subscribers == null)
		{
			subscribers = new Diorite.SingleList<Subscription>(Subscription.equals);
			this.subscribers[abs_path] = subscribers;
		}
		
		bool call_to_subscribe = false;
		var subscription = new Subscription(this, socket, app_id, path, detail);
		if (subscribe)
		{
			call_to_subscribe = subscribers.length == 0;
			subscribers.append(subscription);
			socket.closed.connect(subscription.unsubscribe);
		}
		else
		{
			socket.closed.disconnect(subscription.unsubscribe);
			subscribers.remove(subscription);
			call_to_subscribe = subscribers.length == 0;
		}
		if (call_to_subscribe)
		{
			var builder = new VariantBuilder(new VariantType("a{smv}"));
			builder.add("{smv}", "subscribe", new Variant.boolean(subscribe));
			builder.add("{smv}", "detail", detail != null ? new Variant.string(detail) : null);
			var params = builder.end();
			if (app_id != null)
			{
				var app = app_runners[app_id];
				if (app == null)
					throw new ChannelError.APP_NOT_FOUND("App with id '%s' doesn't exist or HTTP interface is not enabled.", app_id);
				
				yield app.call_full("/nuvola" + path, false, "rws", "dict", params);
			}
			else
			{
				bus.call_local_sync_full("/nuvola" + path, false, "rws", "dict", params);
			}
		}
	}
	
	private void serve_static(RequestContext request)
	{
		
		var path = request.path == "/" ? "index" : request.path.substring(1);
		if (path.has_suffix("/"))
			path += "index";
		
		var file = find_static_file(path);
		if (file == null)
		{
			request.respond_not_found();
			return;
		}
		request.serve_file(file);
	}
	
	private File? find_static_file(string path)
	{
		foreach (var www_root in www_roots)
		{
			var file = www_root.get_child(path);
			if (file.query_file_type(0) == FileType.REGULAR)
				return file;
			file = www_root.get_child(path + ".html");
			if (file.query_file_type(0) == FileType.REGULAR)
				return file;
		}
		return null;
	}
	
	private Json.Node send_app_request(string app_id, AppRequest app_request) throws GLib.Error
	{
		var app = app_runners[app_id];
		var flags = app_request.method == "POST" ? "rw" : "r";
		var method = "/nuvola/%s::%s,dict,".printf(app_request.app_path, flags);
		unowned string? form_data = app_request.method == "POST" ? (string) app_request.body.data : app_request.uri.query;
		return to_json(app.send_message(method, serialize_params(form_data)));
	}
	
	private Json.Node send_local_request(string path, RequestContext request) throws GLib.Error
	{
		var msg = request.msg;
		var body = msg.request_body.flatten();
		var flags = msg.method == "POST" ? "rw" : "r";
		var method = "/nuvola/%s::%s,dict,".printf(path, flags);
		unowned string? form_data = msg.method == "POST" ? (string) body.data : msg.uri.query;
		return to_json(bus.send_local_message(method, serialize_params(form_data)));
	}
	
	private Variant? serialize_params(string? form_data)
	{
		if (form_data != null)
		{
			var query_params = Soup.Form.decode(form_data);
			return Drt.str_table_to_variant_dict(query_params);
		}
		return null;
	}
	
	private Json.Node to_json(Variant? data)
	{
		Variant? result = data;
		if (data == null || !data.get_type().is_subtype_of(VariantType.DICTIONARY))
		{
			var builder = new VariantBuilder(new VariantType("a{smv}"));
			if (data != null)
				g_variant_ref(data); // FIXME: How to avoid this hack
			builder.add("{smv}", "result", data);
			result = builder.end();
		}
		return Json.gvariant_serialize(result);
	}
	
	private Json.Node? list_apps()
	{
		var builder = new Json.Builder();
		builder.begin_object().set_member_name("apps").begin_array();
		var keys = registered_runners.get_values();
		keys.sort(string.collate);
		foreach (var app_id in keys)
			builder.add_string_value(app_id);
		builder.end_array().end_object();
		return builder.get_root();
	}
	
	private Variant? handle_register(GLib.Object source, Drt.ApiParams? params) throws Diorite.MessageError
	{
		register_app(params.pop_string());
		return null;
	}
	
	private Variant? handle_unregister(GLib.Object source, Drt.ApiParams? params) throws Diorite.MessageError
	{
		var app_id = params.pop_string();
		if (!unregister_app(app_id))
			warning("App %s hasn't been registered yet!", app_id);
		return null;
	}
	
	private void on_master_notification(Drt.ApiRouter router, GLib.Object conn, string path, string? detail, Variant? data)
	{
		if (conn != bus)
			return;
		var full_path = "/master" + path;
		var subscribers = this.subscribers[full_path];
		if (subscribers == null)
		{
			warning("No subscriber for %s!", full_path);
			return;
		}
		var path_without_nuvola = "/master" + path.substring(7);
		foreach (var subscriber in subscribers)
				eio_channel.send_notification(subscriber.socket, path_without_nuvola, data);
	}
	
	private void on_app_notification(AppRunner app, string path, string? detail, Variant? data)
	{
		var full_path = "/app/" + app.app_id + path;
		var subscribers = this.subscribers[full_path];
		if (subscribers == null)
		{
			warning("No subscriber for %s!", full_path);
			return;
		}
		var path_without_nuvola = "/app/" + app.app_id + path.substring(7);
		foreach (var subscriber in subscribers)
			eio_channel.send_notification(subscriber.socket, path_without_nuvola, data);
	}
	
	private class Subscription: GLib.Object
	{
		public Server server;
		public Engineio.Socket socket;
		public string? app_id;
		public string path;
		public string? detail;
		
		public Subscription(Server server, Engineio.Socket socket, string? app_id, string path, string? detail)
		{
			assert(socket != null);
			this.server = server;
			this.socket = socket;
			this.app_id = app_id;
			this.path = path;
			this.detail = detail;
		}
		
		public void unsubscribe()
		{
			this.ref(); // Keep alive for a while	
			server.subscribe.begin(app_id, path, false, detail, socket, on_unsubscribe_done);
		}
		
		private void on_unsubscribe_done(GLib.Object? o, AsyncResult res)
		{
			try
			{
				this.unref(); // free
				server.subscribe.end(res);
			}
			catch (GLib.Error e)
			{
				warning("Failed to unsubscribe a closed socket: %s %s", app_id, path);
			}
		}
		
		public bool equals(Subscription other)
		{
			return this == other || this.socket == other.socket && this.app_id == other.app_id && this.path == other.path;
		}
	}
}

} // namespace Nuvola.HttpRemoteControl

// FIXME
private extern Variant* g_variant_ref(Variant* variant);
#endif

