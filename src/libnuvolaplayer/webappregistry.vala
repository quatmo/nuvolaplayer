/*
 * Copyright 2011-2014 Jiří Janoušek <janousek.jiri@gmail.com>
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

namespace Nuvola
{

/**
 *  WebAppRegistry deals with management and loading of service integrations.
 */
public class WebAppRegistry: GLib.Object
{
	private Diorite.Storage storage;
	/**
	 * Name of file with metadata.
	 */
	private static const string METADATA_FILENAME = "metadata.json";
	
	/**
	 * Regular expression to check validity of service identifier
	 */
	private static Regex id_regex;
	
	
	public bool allow_management{ get; private set; }
	
	/**
	 * Creates new web app registry
	 * 
	 * @param storage             storage with service integrations
	 * @param allow_management    whether to allow services management (add/remove)
	 */
	public WebAppRegistry(Diorite.Storage storage, bool allow_management=true)
	{
		this.storage = storage;
		this.allow_management = allow_management;
	}
	
	public WebAppRegistry.with_data_path(Diorite.Storage storage, string path, bool allow_management=false)
	{
		this.storage = new Diorite.Storage(
			path, {},
			storage.user_config_dir.get_path(),
			storage.user_cache_dir.get_path()
		);
		this.allow_management = allow_management;
	}
	
	/**
	 * Emitted when a service has been installed
	 * 
	 * @param id    service's id
	 */
	public signal void app_installed(string id);
	
	/**
	 * Emitted when a service has been removed
	 * 
	 * @param id    service's id
	 */
	public signal void app_removed(string id);
	
	/**
	 * Loads service by id.
	 * 
	 * @param id service id
	 * @return service
	 */
	public WebApp? get_app(string id)
	{
		if  (!check_id(id))
		{
			warning("Service id '%s' is invalid.", id);
			return null;
		}
		WebApp? app = null;
		WebApp? item;
		WebAppMeta? meta = null;
		var app_storage = storage.get_child(id);
		
		var user_dir = app_storage.user_data_dir;
		if (user_dir != null)
		{
			try
			{
				app = load_web_app_from_dir(user_dir, allow_management);
				meta = app.meta;
				debug("Found web app %s at %s, version %u.%u", 
				meta.name, user_dir.get_path(), meta.version_major, meta.version_minor);
			}
			catch (WebAppError e)
			{
				warning("Unable to load web app from %s: %s", user_dir.get_path(), e.message);
			}
		}
		
		foreach (var dir in app_storage.data_dirs)
		{
			try
			{
				item = load_web_app_from_dir(dir);
				meta = item.meta;
				debug("Found app %s at %s, version %u.%u",
				meta.name, dir.get_path(), meta.version_major, meta.version_minor);
				if (app == null || meta.version_major > app.meta.version_major
				|| meta.version_major == app.meta.version_major && meta.version_minor > app.meta.version_minor)
				{
					app = item;
				}
			}
			catch (WebAppError e)
			{
				warning("Unable to load web app from %s: %s", dir.get_path(), e.message);
			}
		}
		
		if (app != null)
			message("Using web app %s, version %u.%u", app.meta.name, app.meta.version_major, app.meta.version_minor);
		
		else
			message("Web App %s not found.", id);
		
		return app;
	}
	
	public WebAppMeta load_web_app_meta_from_dir(File dir) throws WebAppError
	{
		if (dir.query_file_type(0) != FileType.DIRECTORY)
			throw new WebAppError.LOADING_FAILED(@"$(dir.get_path()) is not a directory");
				
		var metadata_file = dir.get_child(METADATA_FILENAME);
		if (metadata_file.query_file_type(0) != FileType.REGULAR)
			throw new WebAppError.LOADING_FAILED(@"$(metadata_file.get_path()) is not a file");
		
		string metadata;
		try
		{
			metadata = Diorite.System.read_file(metadata_file);
		}
		catch (GLib.Error e)
		{
			throw new WebAppError.LOADING_FAILED("Cannot read '%s'. %s", metadata_file.get_path(), e.message);
		}
		
		WebAppMeta? meta;
		try
		{
			meta = Json.gobject_from_data(typeof(WebAppMeta), metadata) as WebAppMeta;
		}
		catch (GLib.Error e)
		{
			throw new WebAppError.INVALID_METADATA("Invalid metadata file '%s'. %s", metadata_file.get_path(), e.message);
		}
		
		meta.check();
		var id = dir.get_basename();
		if (id != meta.id)
			throw new WebAppError.INVALID_METADATA("Invalid metadata file '%s'. Id mismatch.", metadata_file.get_path());
		//			FIXME:
//~ 		if(!JSApi.is_supported(api_major, api_minor)){
//~ 			throw new ServiceError.LOADING_FAILED(
//~ 				"Requested unsupported api: %d.%d'".printf(api_major, api_minor));
//~ 		}
		return meta;
	}
		
	public WebApp load_web_app_from_dir(File dir, bool removable=false) throws WebAppError
	{
		var meta = load_web_app_meta_from_dir(dir);
		var config_dir = storage.get_config_path(meta.id);
		return new WebApp(meta, config_dir, dir, removable);
	}
	
	/**
	 * Lists available services
	 * 
	 * @return hash table of service id - metadata pairs
	 */
	public HashTable<string, WebApp> list_web_apps()
	{
		HashTable<string,  WebApp> result = new HashTable<string, WebApp>(str_hash, str_equal);
		FileInfo file_info;
		WebApp? app;
		WebApp? tmp_app;
		var user_dir = storage.user_data_dir;
		
		if (user_dir.query_exists())
		{
			try
			{
				var enumerator = user_dir.enumerate_children(FileAttribute.STANDARD_NAME, 0);
				while ((file_info = enumerator.next_file()) != null)
				{
					string name = file_info.get_name();
					if (!check_id(name))
						continue;
					
					var app_dir = user_dir.get_child(name);
					if (app_dir.query_file_type(0) != FileType.DIRECTORY)
						continue;
					
					try
					{
						app = load_web_app_from_dir(app_dir, allow_management);
						debug("Found web app %s at %s, version %u.%u",
						app.meta.name, app_dir.get_path(), app.meta.version_major, app.meta.version_minor);
						result.insert(name, app);
					}
					catch (WebAppError e)
					{
						warning("Unable to load app from %s: %s", app_dir.get_path(), e.message);
					}
				}
			}
			catch (GLib.Error e)
			{
				warning("Filesystem error: %s", e.message);
			}
		}
		
		foreach (var dir in storage.data_dirs)
		{
			try
			{
				var enumerator = dir.enumerate_children(FileAttribute.STANDARD_NAME, 0);
				while ((file_info = enumerator.next_file()) != null)
				{
					string name = file_info.get_name();
					if (!check_id(name))
						continue;
					
					var app_dir = dir.get_child(name);
					if (app_dir.query_file_type(0) != FileType.DIRECTORY)
						continue;
					
					try
					{
						app = load_web_app_from_dir(app_dir);
					}
					catch(WebAppError e)
					{
						warning("Unable to load web app from %s: %s", app_dir.get_path(), e.message);
						continue;
					}
					
					debug("Found web app %s at %s, version %u.%u",
					app.meta.name, app_dir.get_path(), app.meta.version_major, app.meta.version_minor);
					
					tmp_app = result.lookup(name);
					
					// Insert new value, if web app has not been added yet,
					// or override previous web app integration, if
					// the new one has greater version.
					if(tmp_app == null
					|| app.meta.version_major > tmp_app.meta.version_major
					|| app.meta.version_major == tmp_app.meta.version_major && app.meta.version_minor > tmp_app.meta.version_minor)
						result.insert(name, app);
				}
			}
			catch (Error e)
			{
				warning("Filesystem error: %s", e.message);
			}
		}
		
		return result;
	}
	
	public WebApp install_app(File package) throws WebAppError
	{
		if (!allow_management)
			throw new WebAppError.NOT_ALLOWED("WebApp management is disabled");
		File tmp_dir;
		try
		{
			tmp_dir = File.new_for_path(DirUtils.make_tmp("nuvolaplayerXXXXXX"));
		}
		catch (FileError e)
		{
			throw new WebAppError.IOERROR(e.message);
		}
		try
		{
			extract_archive(package, tmp_dir);
		
			var control_file = tmp_dir.get_child("control");
			string control_data;
			try
			{
				control_data = Diorite.System.read_file(control_file);
			}
			catch (GLib.Error e)
			{
				throw new WebAppError.IOERROR("Cannot read '%s'. %s", control_file.get_path(), e.message);
			}
			
			const string GROUP = "package";
			control_data = "[%s]\n%s".printf(GROUP, control_data);
			var control = new KeyFile();
			string web_app_id;
			try
			{
				control.load_from_data(control_data, -1, KeyFileFlags.NONE);
				var format = control.get_integer(GROUP, "format");
				web_app_id = control.get_string(GROUP, "app_id");
				if (format != 3 || web_app_id == null || web_app_id == "")
					throw new WebAppError.INVALID_FILE("Package has wrong format.");
			}
			catch (KeyFileError e)
			{
				throw new WebAppError.INVALID_FILE("Invalid control file '%s'. %s", control_file.get_path(), e.message);
			}
			
			var web_app_dir = tmp_dir.get_child(web_app_id);
			if (web_app_dir.query_file_type(0) != FileType.DIRECTORY)
				throw new WebAppError.INVALID_FILE("Package does not contain directory '%s'.", web_app_id);
			
			load_web_app_from_dir(web_app_dir); // throws WebAppError
			
			var destination = storage.get_data_path(web_app_id);
			if (destination.query_exists())
			{
				try
				{
					Diorite.System.purge_directory_content(destination, true);
					destination.delete();
				}
				catch (GLib.Error e)
				{
					throw new WebAppError.IOERROR("Cannot purge dir '%s'. %s", destination.get_path(), e.message);
				}
			}
			else
			{
				try
				{
					destination.get_parent().make_directory_with_parents();
				}
				catch (Error e)
				{
					// Not fatal
				}
			}
			
			try
			{
				var cancellable = new Cancellable();
				web_app_dir.move(destination, FileCopyFlags.NONE, cancellable, null);
			}
			catch (GLib.Error e)
			{
				try
				{
					Diorite.System.purge_directory_content(destination, true);
					destination.delete();
				}
				catch (GLib.Error e2)
				{
					warning("Cannot purge dir '%s'. %s", destination.get_path(), e2.message);
				}
				
				throw new WebAppError.IOERROR("Cannot copy integration to '%s'. %s", destination.get_path(), e.message);
			}
			
			var web_app = load_web_app_from_dir(destination); // throws WebAppError
			app_installed(web_app.meta.id);
			return web_app;
		}
		catch (ArchiveError e)
		{
			throw new WebAppError.EXTRACT_ERROR("Failed to extract package '%s'. %s", package.get_path(), e.message);
		}
		finally
		{
			Diorite.System.try_purge_dir(tmp_dir);
		}
	}
	
	private void extract_archive(File archive, File directory) throws ArchiveError
	{
		var current_dir = Environment.get_current_dir();
		if (Environment.set_current_dir(directory.get_path()) < 0)
			throw new ArchiveError.SYSTEM_ERROR("Failed to chdir to '%s'.", directory.get_path());
		
		Archive.Read reader;
		try
		{
			reader = new Archive.Read();
			if (reader.support_format_tar() != Archive.Result.OK)
				throw new ArchiveError.READ_ERROR("Cannot enable tar format. %s", reader.error_string());
			if (reader.support_compression_gzip() != Archive.Result.OK)
				throw new ArchiveError.READ_ERROR("Cannot enable gzip compression. %s", reader.error_string());
			if (reader.open_filename(archive.get_path(), 10240) != Archive.Result.OK)
				throw new ArchiveError.READ_ERROR("Cannot open archive '%s'. %s", archive.get_path(), reader.error_string());
			
			var writer = new Archive.WriteDisk();
			writer.set_options(Archive.ExtractFlags.TIME | Archive.ExtractFlags.SECURE_NODOTDOT | Archive.ExtractFlags.SECURE_SYMLINKS);
			
			while (true)
			{
				unowned Archive.Entry entry;
				var result = reader.next_header(out entry);
				if (result == Archive.Result.EOF)
					break;
				if (result != Archive.Result.OK)
					throw new ArchiveError.READ_ERROR("Failed to read next header. %s", reader.error_string());
				debug("Extract '%s'", entry.pathname());
				if (writer.write_header(entry) != Archive.Result.OK)
					throw new ArchiveError.WRITE_ERROR("Failed to write header. %s", writer.error_string());
				
				void* buff;
				size_t size;
				Archive.off_t offset;
			
				while (true)
				{
					result = reader.read_data_block (out buff, out size, out offset);
					if (result == Archive.Result.EOF)
						break;
					if (result != Archive.Result.OK)
						throw new ArchiveError.READ_ERROR("Failed to read data. %s", reader.error_string());
					if (writer.write_data_block(buff, size, offset) != Archive.Result.OK)
						throw new ArchiveError.WRITE_ERROR("Failed to write data. %s", writer.error_string()); 
				}
				
				if (writer.finish_entry() != Archive.Result.OK)
					throw new ArchiveError.WRITE_ERROR("Failed to finish entry. %s", writer.error_string());
			}
		}
		finally
		{
			reader.close();
			if (Environment.set_current_dir(current_dir) < 0)
				warning("Failed to chdir back to '%s'.", current_dir);
		}
	}
	
	/**
	 * Check if the service identifier is valid
	 * 
	 * @param id service identifier
	 * @return true if id is valid
	 */
	public static bool check_id(string id)
	{
		if (id_regex == null)
		{
			try
			{
				id_regex = new Regex("^\\w+$");
			}
			catch (RegexError e)
			{
				error("Unable to compile regular expression /^\\w+$/.");
			}
		}
		return id_regex.match(id);
	}
}

public errordomain WebAppError
{
	INVALID_METADATA,
	LOADING_FAILED,
	COMMAND_FAILED,
	INVALID_FILE,
	IOERROR,
	NOT_ALLOWED,
	SERVER_ERROR,
	SERVER_ERROR_MESSAGE,
	EXTRACT_ERROR;
}

public errordomain ArchiveError
{
	SYSTEM_ERROR,
	READ_ERROR,
	WRITE_ERROR;
}

} // namespace Nuvola
