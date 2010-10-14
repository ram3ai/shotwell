/* Copyright 2009-2010 Yorba Foundation
 *
 * This software is licensed under the GNU LGPL (version 2.1 or later).
 * See the COPYING file in this distribution. 
 */

public class Thumbnail : CheckerboardItem {
    // Collection properties Thumbnail responds to
    // SHOW_TAGS (bool)
    public const string PROP_SHOW_TAGS = CheckerboardItem.PROP_SHOW_SUBTITLES;
    // SIZE (int, scale)
    public const string PROP_SIZE = "thumbnail-size";
    // SHOW_RATINGS (bool)
    public const string PROP_SHOW_RATINGS = "show-ratings";
    
    public const int MIN_SCALE = 72;
    public const int MAX_SCALE = ThumbnailCache.Size.LARGEST.get_scale();
    public const int DEFAULT_SCALE = ThumbnailCache.Size.MEDIUM.get_scale();
    
    public const Gdk.InterpType LOW_QUALITY_INTERP = Gdk.InterpType.NEAREST;
    public const Gdk.InterpType HIGH_QUALITY_INTERP = Gdk.InterpType.BILINEAR;
    
    private const int HQ_IMPROVEMENT_MSEC = 100;
    
    private LibraryPhoto? photo;
    private Video? video;
    private int scale;
    private Dimensions original_dim;
    private Dimensions dim;
    private Gdk.Pixbuf unscaled_pixbuf = null;
    private Cancellable cancellable = null;
    private bool hq_scheduled = false;
    private bool hq_reschedule = false;
    // this is cached locally because there are situations where the constant calls to is_exposed()
    // was showing up in sysprof
    private bool exposure = false;
    
    public Thumbnail(MediaSource source, int scale = DEFAULT_SCALE) {
        base (source, source.get_dimensions().get_scaled(scale, true), source.get_name());
        
        if (source is LibraryPhoto) {
            this.video = null;
            this.photo = (LibraryPhoto) source;

            Tag.global.container_contents_altered.connect(on_tag_contents_altered);
            Tag.global.items_altered.connect(on_tags_altered);
            LibraryPhoto.global.items_altered.connect(on_sources_altered);
        } else if (source is Video) {
            this.video = (Video) source;
            this.photo = null;
            
            Video.global.items_altered.connect(on_sources_altered);
        }

        this.scale = scale;
        
        original_dim = source.get_dimensions();
        dim = original_dim.get_scaled(scale, true);
    }

    ~Thumbnail() {
        if (cancellable != null)
            cancellable.cancel();
        
        if (photo != null) {
            Tag.global.container_contents_altered.disconnect(on_tag_contents_altered);
            Tag.global.items_altered.disconnect(on_tags_altered);
            LibraryPhoto.global.items_altered.disconnect(on_sources_altered);
        } else if (video != null) {
            Video.global.items_altered.disconnect(on_sources_altered);
        }
    }
    
    private void update_tags() {
        // if this is a thumbnail for a video, then photo can be null, so do a short-circuit
        // return when it is; later, when we support tagging videos, we can implement tag
        // updates on video objects
        if (photo == null)
            return;

        Gee.Collection<Tag>? tags = Tag.global.fetch_sorted_for_photo(photo);
        if (tags == null || tags.size == 0)
            clear_subtitle();
        else
            set_subtitle(Tag.make_tag_string(tags, "<small>", ", ", "</small>", true), true);
    }
    
    private void on_tag_contents_altered(ContainerSource container, Gee.Collection<DataSource>? added,
        Gee.Collection<DataSource>? removed) {
        if (!exposure)
            return;
        
        bool tag_added = (added != null) ? added.contains(photo) : false;
        bool tag_removed = (removed != null) ? removed.contains(photo) : false;
        
        // if photo we're monitoring is added or removed to any tag, update tag list
        if (tag_added || tag_removed)
            update_tags();
    }
    
    private void on_tags_altered(Gee.Map<DataObject, Alteration> altered) {
        if (!exposure)
            return;
        
        foreach (DataObject object in altered.keys) {
            Tag tag = (Tag) object;
            
            if ((!is_video()) && tag.contains(photo)) {
                update_tags();
                
                break;
            }
        }
    }
    
    private void update_title() {
        string title = get_media_source().get_name();
        if (is_string_empty(title))
            clear_title();
        else
            set_title(title);
    }
    
    private void on_sources_altered(Gee.Map<DataObject, Alteration> map) {
        if (!exposure || !map.has_key(get_media_source()))
            return;
        
        if (map.get(get_media_source()).has_detail("metadata", "name"))
            update_title();
    }
    
    public LibraryPhoto get_photo() {
        // There's enough overhead with 10,000 photos and casting from get_source() to do it this way
        return photo;
    }
    
    public Video get_video() {
        return video;
    }
    
    public MediaSource get_media_source() {
        if (is_video())
            return video;
        else
            return photo;
    }
    
    //
    // Comparators
    //

    public static int64 photo_id_ascending_comparator(void *a, void *b) {
        return strcmp(((Thumbnail *) a)->get_unique_identifier(),
            ((Thumbnail *) b)->get_unique_identifier());
    }

    public static int64 photo_id_descending_comparator(void *a, void *b) {
        return photo_id_ascending_comparator(b, a);
    }
    
    public static int64 title_ascending_comparator(void *a, void *b) {
        int64 result = strcmp(((Thumbnail *) a)->get_name(), ((Thumbnail *) b)->get_name());
        
        return (result != 0) ? result : photo_id_ascending_comparator(a, b);
    }
    
    public static int64 title_descending_comparator(void *a, void *b) {
        int64 result = title_ascending_comparator(b, a);
        
        return (result != 0) ? result : photo_id_descending_comparator(a, b);
    }
    
    public static bool title_comparator_predicate(DataObject object, Alteration alteration) {
        return alteration.has_detail("metadata", "title");
    }
    
    public static int64 exposure_time_ascending_comparator(void *a, void *b) {
        int64 result = ((Thumbnail *) a)->get_exposure_time() - ((Thumbnail *) b)->get_exposure_time();
        
        return (result != 0) ? result : photo_id_ascending_comparator(a, b);
    }
    
    public static int64 exposure_time_desending_comparator(void *a, void *b) {
        int64 result = exposure_time_ascending_comparator(b, a);
        
        return (result != 0) ? result : photo_id_descending_comparator(a, b);
    }
    
    public static bool exposure_time_comparator_predicate(DataObject object, Alteration alteration) {
        return alteration.has_detail("metadata", "exposure-time");
    }
    
    public static int64 rating_ascending_comparator(void *a, void *b) {
        int64 result = ((Thumbnail *) a)->get_rating() - ((Thumbnail *) b)->get_rating();
        
        return (result != 0) ? result : photo_id_ascending_comparator(a, b);
    }

    public static int64 rating_descending_comparator(void *a, void *b) {
        int64 result = rating_ascending_comparator(b, a);
        
        return (result != 0) ? result : photo_id_descending_comparator(a, b);
    }
    
    public static bool rating_comparator_predicate(DataObject object, Alteration alteration) {
        return alteration.has_detail("metadata", "rating");
    }
    
    protected override void thumbnail_altered() {
        original_dim = (is_video()) ? video.get_frame_dimensions() : get_photo().get_dimensions();
        dim = original_dim.get_scaled(scale, true);
        
        if (exposure)
            schedule_low_quality_fetch();
        else
            paint_empty();
        
        base.thumbnail_altered();
    }
    
    protected override void notify_collection_property_set(string name, Value? old, Value val) {
        switch (name) {
            case PROP_SIZE:
                resize((int) val);
            break;
            case PROP_SHOW_RATINGS:
                notify_view_altered();
            break;
        }
        
        base.notify_collection_property_set(name, old, val);
    }
    
    private void resize(int new_scale) {
        assert(new_scale >= MIN_SCALE);
        assert(new_scale <= MAX_SCALE);
        
        if (scale == new_scale)
            return;
        
        scale = new_scale;
        dim = original_dim.get_scaled(scale, true);
        
        cancel_async_fetch();
        
        if (exposure) {
            // attempt to use an unscaled pixbuf (which is always larger or equal to the current
            // size, and will most likely be larger than the new size -- and if not, a new one will
            // be on its way), then use the current pixbuf if available (which may have to be
            // scaled up, which is ugly)
            Gdk.Pixbuf? resizable = null;
            if (unscaled_pixbuf != null)
                resizable = unscaled_pixbuf;
            else if (has_image())
                resizable = get_image();
            
            if (resizable != null)
                set_image(resize_pixbuf(resizable, dim, LOW_QUALITY_INTERP));
            
            delayed_high_quality_fetch();
        } else {
            clear_image(dim);
        }
    }
    
    private void paint_empty() {
        cancel_async_fetch();
        clear_image(dim);
        unscaled_pixbuf = null;
    }
    
    private void schedule_low_quality_fetch() {
        cancel_async_fetch();
        cancellable = new Cancellable();

            // VALA: ideally, we'd use the ternary operator here and insert the ternary
            //       expression directly in the fetch_async_scaled( ) called below,
            //       but on both valac 0.8.0 and 0.9.3, this results in a parse error
            //       "incompatible expressions"
            ThumbnailSource source = null;
            if (is_video())
                source = video;
            else
                source = photo;

        ThumbnailCache.fetch_async_scaled(source, ThumbnailCache.Size.SMALLEST, 
            dim, LOW_QUALITY_INTERP, on_low_quality_fetched, cancellable);
    }
    
    private void delayed_high_quality_fetch() {
        if (hq_scheduled) {
            hq_reschedule = true;
            
            return;
        }
        
        Timeout.add_full(Priority.DEFAULT, HQ_IMPROVEMENT_MSEC, on_schedule_high_quality);
        hq_scheduled = true;
    }
    
    private bool on_schedule_high_quality() {
        if (hq_reschedule) {
            hq_reschedule = false;
            
            return true;
        }
        
        cancel_async_fetch();
        cancellable = new Cancellable();
        
        if (exposure) {
            // VALA: ideally, we'd use the ternary operator here and insert the ternary
            //       expression directly in the fetch_async_scaled( ) called below,
            //       but on both valac 0.8.0 and 0.9.3, this results in a parse error
            //       "incompatible expressions"
            ThumbnailSource source = null;
            if (is_video())
                source = video;
            else
                source = photo;

            ThumbnailCache.fetch_async_scaled(source, scale, dim,
                HIGH_QUALITY_INTERP, on_high_quality_fetched, cancellable);
        }
        
        hq_scheduled = false;
        
        return false;
    }
    
    private void cancel_async_fetch() {
        // cancel outstanding I/O
        if (cancellable != null)
            cancellable.cancel();
    }
    
    private void on_low_quality_fetched(Gdk.Pixbuf? pixbuf, Gdk.Pixbuf? unscaled, Dimensions dim,
        Gdk.InterpType interp, Error? err) {
        if (err != null)
            critical("Unable to fetch low-quality thumbnail for %s (scale: %d): %s", to_string(), scale,
                err.message);
        
        if (pixbuf != null)
            set_image(pixbuf);
        
        if (unscaled != null)
            unscaled_pixbuf = unscaled;
        
        delayed_high_quality_fetch();
    }
    
    private void on_high_quality_fetched(Gdk.Pixbuf? pixbuf, Gdk.Pixbuf? unscaled, Dimensions dim,
        Gdk.InterpType interp, Error? err) {
        if (err != null)
            critical("Unable to fetch high-quality thumbnail for %s (scale: %d): %s", to_string(), scale, 
                err.message);
        
        if (pixbuf != null)
            set_image(pixbuf);
        
        if (unscaled != null)
            unscaled_pixbuf = unscaled;
    }
    
    public override void exposed() {
        exposure = true;
        
        if (!has_image())
            schedule_low_quality_fetch();
        
        update_title();
        update_tags();
        
        base.exposed();
    }
    
    public override void unexposed() {
        exposure = false;
        
        paint_empty();
        
        base.unexposed();
    }
    
    public override Gee.List<Gdk.Pixbuf>? get_trinkets(int scale) {
        Rating rating = get_rating();
        
        bool show_ratings = false;
        Value? val = get_collection_property(PROP_SHOW_RATINGS);
        if (val != null)
            show_ratings = (bool)val;
        
        // don't let the hose run
        if (rating == Rating.UNRATED || show_ratings == false)
            return null;
        
        Gee.List<Gdk.Pixbuf> trinkets = new Gee.ArrayList<Gdk.Pixbuf>();
        
        Gdk.Pixbuf? rating_buf = Resources.get_rating_trinket(rating, scale);
        if (rating_buf != null)
            trinkets.add(rating_buf);
        
        return trinkets;
    }
    
    public bool is_video() {
        return (video != null);
    }
    
    private string get_unique_identifier() {
        return (is_video()) ? video.get_source_id() : photo.get_source_id();
    }
    
    public time_t get_exposure_time() {
        return (is_video()) ? video.get_exposure_time() : photo.get_exposure_time();
    }
    
    public Rating get_rating() {
        return get_media_source().get_rating();
    }
}
