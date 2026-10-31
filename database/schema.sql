--
-- PostgreSQL database dump
--

\restrict UyPE0WhxFU3M7WcYk3SAGskfq1JdM3dVGkcmhIouuI49OydQAfEDYIIITh2xE0n

-- Dumped from database version 18.6
-- Dumped by pg_dump version 18.6

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: create_booking(integer, date, time without time zone, character varying, character varying, character varying, character varying, integer, character, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_booking(p_service_id integer, p_appointment_date date, p_appointment_time time without time zone, p_first_name character varying, p_last_name character varying, p_email character varying, p_phone character varying, p_classification_id integer DEFAULT NULL::integer, p_is_priority character DEFAULT 'N'::bpchar, p_user_id integer DEFAULT NULL::integer) RETURNS TABLE(appointment_id bigint, booking_reference character varying)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_duration INTEGER;
    v_price    NUMERIC(8,2);
    v_end      TIME;
    v_buffer   INTERVAL := make_interval(mins => setting_num('BUFFER_MINUTES', 15)::INT);
    v_customer BIGINT;
    v_staff    SMALLINT;
    v_appt     BIGINT;
    v_ref      VARCHAR(40);
    v_seq      INTEGER;
BEGIN
    SELECT s.duration_min, s.current_price
      INTO v_duration, v_price
      FROM services s
     WHERE s.service_id = p_service_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown service %', p_service_id USING ERRCODE = 'DRM03';
    END IF;

    v_end := p_appointment_time + make_interval(mins => v_duration);

    -- the owner-specialist: one person, one lane
    SELECT MIN(st.staff_id) INTO v_staff FROM staff st;

    ------------------------------------------------------------------------
    -- Hold the day, then re-check.
    --
    -- Between the page listing its free slots and the customer pressing book,
    -- somebody else may have taken the same time. This advisory lock is held
    -- until the transaction ends and serialises bookings for THIS DAY only, so
    -- two people booking different days never wait on each other. It works even
    -- when the day has no rows yet, which a SELECT ... FOR UPDATE would not.
    ------------------------------------------------------------------------
    PERFORM pg_advisory_xact_lock(hashtext('dermalytics_day_' || p_appointment_date::TEXT));

    IF EXISTS (SELECT 1
                 FROM appointments a
                WHERE a.appointment_date = p_appointment_date
                  AND a.status_id IN (1, 2, 5)
                  AND a.appointment_time < v_end + v_buffer
                  AND a.end_time         > p_appointment_time - v_buffer) THEN
        RAISE EXCEPTION 'That time has just been taken. Please choose another slot.'
            USING ERRCODE = 'DRM01';
    END IF;

    IF EXISTS (SELECT 1 FROM clinic_closures c WHERE c.closure_date = p_appointment_date) THEN
        RAISE EXCEPTION 'The clinic is closed on %', p_appointment_date
            USING ERRCODE = 'DRM02';
    END IF;

    ------------------------------------------------------------------------
    -- The customer: match an existing one on email or phone, else create
    -- (BR-001, BR-003). Guests book without an account, so user_id stays NULL.
    ------------------------------------------------------------------------
    SELECT MIN(c.customer_id) INTO v_customer
      FROM customers c
     WHERE LOWER(c.email) = LOWER(p_email)
        OR c.phone_number = p_phone;

    IF v_customer IS NULL THEN
        INSERT INTO customers (customer_id, first_name, last_name, email, phone_number,
                               user_id, registration_date, acquisition_channel, customer_status)
        VALUES (nextval('seq_customer'), p_first_name, p_last_name, p_email, p_phone,
                p_user_id, CURRENT_DATE, 'Website', 'Active')
        RETURNING customers.customer_id INTO v_customer;
    END IF;

    ------------------------------------------------------------------------
    -- The appointment
    ------------------------------------------------------------------------
    v_appt := nextval('seq_appointment');

    SELECT COALESCE(MAX(SUBSTRING(a.booking_reference FROM 10)::INTEGER), 0) + 1
      INTO v_seq
      FROM appointments a
     WHERE a.booking_reference LIKE 'DRM-' || TO_CHAR(CURRENT_DATE, 'YYYY') || '-%';

    v_ref := 'DRM-' || TO_CHAR(CURRENT_DATE, 'YYYY') || '-' || LPAD(v_seq::TEXT, 5, '0');

    INSERT INTO appointments (
        appointment_id, customer_id, service_id, staff_id,
        appointment_date, appointment_time, end_time, duration_min,
        price_charged, status_id, booking_datetime, booking_channel,
        booking_reference, is_priority, classification_id, notes)
    VALUES (
        v_appt, v_customer, p_service_id, v_staff,
        p_appointment_date, p_appointment_time, v_end, v_duration,
        v_price, 1, now(), 'Website',
        v_ref, COALESCE(p_is_priority, 'N'), p_classification_id,
        CASE WHEN p_classification_id IS NOT NULL
             THEN 'Booked after ML skin analysis (recommendation only, not a diagnosis)'
        END);

    -- BR-029: every status change is logged
    INSERT INTO appointment_status_history (history_id, appointment_id, status_id,
                                            changed_at, changed_by_user_id)
    VALUES (nextval('seq_status_history'), v_appt, 1, now(), p_user_id);

    -- record the first visit once it is known
    UPDATE customers c
       SET first_visit_date = LEAST(COALESCE(c.first_visit_date, p_appointment_date),
                                    p_appointment_date)
     WHERE c.customer_id = v_customer;

    RETURN QUERY SELECT v_appt, v_ref;
END;
$$;


--
-- Name: get_available_slots(integer, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_available_slots(p_service_id integer, p_appointment_date date) RETURNS TABLE(start_time time without time zone, end_time time without time zone)
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    v_open     TIME;
    v_close    TIME;
    v_duration INTERVAL;
    v_buffer   INTERVAL := make_interval(mins => setting_num('BUFFER_MINUTES', 15)::INT);
    v_step     INTERVAL := make_interval(mins => setting_num('SLOT_STEP_MINUTES', 15)::INT);
    v_lead     INTERVAL := INTERVAL '1 hour';   -- no same-day booking inside the next hour
BEGIN
    -- never offer a day in the past
    IF p_appointment_date < CURRENT_DATE THEN
        RETURN;
    END IF;

    -- closed weekday? (ISO: 1 = Monday .. 7 = Sunday)
    SELECT wh.open_time, wh.close_time
      INTO v_open, v_close
      FROM working_hours wh
     WHERE wh.day_of_week = EXTRACT(ISODOW FROM p_appointment_date)
       AND wh.is_open = 'Y';

    IF NOT FOUND THEN
        RETURN;
    END IF;

    -- public holiday or annual break?
    IF EXISTS (SELECT 1 FROM clinic_closures c WHERE c.closure_date = p_appointment_date) THEN
        RETURN;
    END IF;

    SELECT make_interval(mins => s.duration_min)
      INTO v_duration
      FROM services s
     WHERE s.service_id = p_service_id
       AND s.is_active = 'Y';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Service % is not available for booking', p_service_id
            USING ERRCODE = 'DRM03';
    END IF;

    RETURN QUERY
    WITH candidate AS (
        SELECT g::TIME                 AS s_time,
               (g + v_duration)::TIME  AS e_time,
               g                       AS s_stamp
          FROM generate_series(p_appointment_date + v_open,
                               p_appointment_date + v_close - v_duration,
                               v_step) AS g
    )
    SELECT c.s_time, c.e_time
      FROM candidate c
     WHERE c.s_stamp > now() + v_lead                 -- not in the past, not imminent
       AND NOT EXISTS (
             SELECT 1
               FROM appointments a
              WHERE a.appointment_date = p_appointment_date
                AND a.status_id IN (1, 2, 5)          -- Scheduled, Rescheduled, Completed
                AND a.appointment_time < c.e_time + v_buffer
                AND a.end_time         > c.s_time - v_buffer)
     ORDER BY c.s_time;
END;
$$;


--
-- Name: setting_num(character varying, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.setting_num(p_key character varying, p_default numeric) RETURNS numeric
    LANGUAGE sql STABLE
    AS $$
    SELECT COALESCE((SELECT setting_value::NUMERIC
                       FROM system_settings
                      WHERE setting_key = p_key), p_default);
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: appointment_status; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.appointment_status (
    status_id smallint NOT NULL,
    status_name character varying(30) NOT NULL,
    description character varying(200) NOT NULL,
    is_final character(1) NOT NULL
);


--
-- Name: appointment_status_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.appointment_status_history (
    history_id bigint NOT NULL,
    appointment_id bigint NOT NULL,
    status_id smallint NOT NULL,
    changed_at timestamp without time zone NOT NULL,
    changed_by_user_id bigint
);


--
-- Name: appointments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.appointments (
    appointment_id bigint NOT NULL,
    customer_id bigint NOT NULL,
    service_id smallint NOT NULL,
    staff_id smallint NOT NULL,
    appointment_date date NOT NULL,
    appointment_time time without time zone NOT NULL,
    end_time time without time zone NOT NULL,
    duration_min smallint NOT NULL,
    price_charged numeric(8,2) NOT NULL,
    status_id smallint NOT NULL,
    booking_datetime timestamp without time zone NOT NULL,
    booking_channel character varying(20) NOT NULL,
    booking_reference character varying(40),
    is_priority character(1) NOT NULL,
    classification_id bigint,
    rescheduled_from_id bigint,
    cancellation_datetime timestamp without time zone,
    notes character varying(200),
    CONSTRAINT ck_appointments_1 CHECK ((end_time > appointment_time)),
    CONSTRAINT ck_appointments_2 CHECK ((booking_datetime < (appointment_date + appointment_time))),
    CONSTRAINT ck_appointments_3 CHECK ((is_priority = ANY (ARRAY['Y'::bpchar, 'N'::bpchar]))),
    CONSTRAINT ck_appointments_4 CHECK ((((booking_channel)::text = 'Website'::text) = (booking_reference IS NOT NULL))),
    CONSTRAINT ck_appointments_5 CHECK (((rescheduled_from_id IS NULL) OR (rescheduled_from_id <> appointment_id)))
);


--
-- Name: audit_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_log (
    audit_id bigint NOT NULL,
    user_id bigint NOT NULL,
    action_type character varying(20) NOT NULL,
    table_name character varying(30) NOT NULL,
    record_id bigint,
    action_datetime timestamp without time zone NOT NULL,
    details character varying(250) NOT NULL
);


--
-- Name: clinic_closures; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.clinic_closures (
    closure_id integer NOT NULL,
    closure_date date NOT NULL,
    reason character varying(100) NOT NULL
);


--
-- Name: customers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.customers (
    customer_id bigint NOT NULL,
    first_name character varying(50) NOT NULL,
    last_name character varying(50) NOT NULL,
    age smallint,
    gender character varying(10),
    email character varying(120) NOT NULL,
    phone_number character varying(20) NOT NULL,
    user_id bigint,
    registration_date date NOT NULL,
    first_visit_date date,
    acquisition_channel character varying(30),
    customer_status character varying(10) NOT NULL,
    CONSTRAINT ck_customers_1 CHECK (((age IS NULL) OR ((age >= 0) AND (age <= 120)))),
    CONSTRAINT ck_customers_2 CHECK (((first_visit_date IS NULL) OR (first_visit_date >= registration_date))),
    CONSTRAINT ck_customers_3 CHECK (((customer_status)::text = ANY (ARRAY[('Active'::character varying)::text, ('Inactive'::character varying)::text])))
);


--
-- Name: dim_date; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.dim_date (
    date_key integer NOT NULL,
    full_date date NOT NULL,
    day_name character varying(10) NOT NULL,
    day_of_week smallint NOT NULL,
    week_of_year smallint NOT NULL,
    month_num smallint NOT NULL,
    month_name character varying(10) NOT NULL,
    quarter smallint NOT NULL,
    year_num smallint NOT NULL,
    is_open_day character(1) NOT NULL,
    is_closure character(1) NOT NULL
);


--
-- Name: expense_categories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.expense_categories (
    expense_category_id smallint NOT NULL,
    category_name character varying(60) NOT NULL,
    is_recurring character(1) NOT NULL
);


--
-- Name: expenses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.expenses (
    expense_id bigint NOT NULL,
    expense_category_id smallint NOT NULL,
    expense_type character varying(60) NOT NULL,
    description character varying(200) NOT NULL,
    amount numeric(10,2) NOT NULL,
    expense_date date NOT NULL,
    payment_method character varying(20) NOT NULL,
    expense_status character varying(10) NOT NULL,
    vendor character varying(80) NOT NULL,
    CONSTRAINT ck_expenses_1 CHECK ((amount >= (0)::numeric))
);


--
-- Name: image_uploads; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.image_uploads (
    image_id bigint NOT NULL,
    customer_id bigint NOT NULL,
    upload_datetime timestamp without time zone NOT NULL,
    file_path character varying(200) NOT NULL,
    file_format character varying(10) NOT NULL
);


--
-- Name: medical_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.medical_history (
    record_id bigint NOT NULL,
    customer_id bigint NOT NULL,
    record_date date NOT NULL,
    skin_type character varying(20) NOT NULL,
    conditions character varying(200) NOT NULL,
    allergies character varying(100) NOT NULL,
    notes character varying(300) NOT NULL,
    recorded_by_staff_id smallint NOT NULL
);


--
-- Name: ml_classifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ml_classifications (
    classification_id bigint NOT NULL,
    image_id bigint NOT NULL,
    classified_at timestamp without time zone NOT NULL,
    urgency_level character varying(30) NOT NULL,
    confidence_score numeric(3,2) NOT NULL,
    model_version character varying(30) NOT NULL,
    recommended_action character varying(250) NOT NULL,
    review_required character(1) NOT NULL,
    CONSTRAINT ck_ml_classifications_1 CHECK (((confidence_score >= (0)::numeric) AND (confidence_score <= (1)::numeric))),
    CONSTRAINT ck_ml_classifications_2 CHECK (((urgency_level)::text = ANY (ARRAY[('Low'::character varying)::text, ('Moderate'::character varying)::text, ('High'::character varying)::text, ('Manual Review Required'::character varying)::text]))),
    CONSTRAINT ck_ml_classifications_3 CHECK (((confidence_score < 0.60) = (review_required = 'Y'::bpchar)))
);


--
-- Name: payments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.payments (
    payment_id bigint NOT NULL,
    appointment_id bigint NOT NULL,
    customer_id bigint NOT NULL,
    payment_type character varying(20) NOT NULL,
    payment_date date NOT NULL,
    amount_due numeric(10,2) NOT NULL,
    discount_amount numeric(10,2) NOT NULL,
    amount_paid numeric(10,2) NOT NULL,
    payment_method character varying(20) NOT NULL,
    payment_status character varying(15) NOT NULL,
    is_validated character(1) NOT NULL,
    refund_date date,
    refund_amount numeric(10,2),
    CONSTRAINT ck_payments_1 CHECK (((amount_due >= (0)::numeric) AND (amount_paid >= (0)::numeric) AND (discount_amount >= (0)::numeric))),
    CONSTRAINT ck_payments_2 CHECK (((refund_date IS NULL) OR (refund_date >= payment_date))),
    CONSTRAINT ck_payments_3 CHECK (((payment_status)::text = ANY (ARRAY[('Completed'::character varying)::text, ('Pending'::character varying)::text, ('Partial'::character varying)::text, ('Failed'::character varying)::text, ('Refunded'::character varying)::text]))),
    CONSTRAINT ck_payments_4 CHECK ((is_validated = ANY (ARRAY['Y'::bpchar, 'N'::bpchar])))
);


--
-- Name: roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.roles (
    role_id smallint NOT NULL,
    role_name character varying(40) NOT NULL
);


--
-- Name: seq_appointment; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.seq_appointment
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: seq_audit; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.seq_audit
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: seq_classification; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.seq_classification
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: seq_closure; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.seq_closure
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: seq_customer; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.seq_customer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: seq_expense; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.seq_expense
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: seq_image; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.seq_image
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: seq_interaction; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.seq_interaction
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: seq_medical; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.seq_medical
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: seq_payment; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.seq_payment
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: seq_price; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.seq_price
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: seq_status_history; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.seq_status_history
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: seq_user; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.seq_user
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: service_price_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.service_price_history (
    price_id integer NOT NULL,
    service_id smallint NOT NULL,
    price numeric(8,2) NOT NULL,
    valid_from date NOT NULL,
    valid_to date,
    CONSTRAINT ck_service_price_history_1 CHECK (((valid_to IS NULL) OR (valid_to >= valid_from)))
);


--
-- Name: services; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.services (
    service_id smallint NOT NULL,
    service_name character varying(60) NOT NULL,
    category character varying(30) NOT NULL,
    description character varying(400) NOT NULL,
    duration_min smallint NOT NULL,
    current_price numeric(8,2) NOT NULL,
    is_active character(1) NOT NULL,
    CONSTRAINT ck_services_1 CHECK ((duration_min > 0)),
    CONSTRAINT ck_services_2 CHECK ((current_price >= (0)::numeric))
);


--
-- Name: staff; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.staff (
    staff_id smallint NOT NULL,
    user_id bigint NOT NULL,
    full_name character varying(100) NOT NULL,
    "position" character varying(60) NOT NULL,
    phone character varying(20) NOT NULL,
    hire_date date NOT NULL
);


--
-- Name: system_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.system_settings (
    setting_key character varying(50) NOT NULL,
    setting_value character varying(100) NOT NULL,
    description character varying(250) NOT NULL
);


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    user_id bigint NOT NULL,
    role_id smallint NOT NULL,
    username character varying(60) NOT NULL,
    email character varying(120) NOT NULL,
    password_hash character varying(100) NOT NULL,
    is_active character(1) NOT NULL,
    created_at timestamp without time zone NOT NULL
);


--
-- Name: website_interactions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.website_interactions (
    interaction_id bigint NOT NULL,
    session_id character varying(12) NOT NULL,
    customer_id bigint,
    interaction_datetime timestamp without time zone NOT NULL,
    interaction_type character varying(30) NOT NULL,
    page_url character varying(120) NOT NULL,
    service_id smallint,
    appointment_id bigint,
    classification_id bigint,
    device_type character varying(10) NOT NULL,
    traffic_source character varying(20) NOT NULL
);


--
-- Name: working_hours; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.working_hours (
    day_of_week smallint NOT NULL,
    day_name character varying(10) NOT NULL,
    is_open character(1) NOT NULL,
    open_time time without time zone,
    close_time time without time zone,
    CONSTRAINT ck_working_hours_1 CHECK (((day_of_week >= 1) AND (day_of_week <= 7))),
    CONSTRAINT ck_working_hours_2 CHECK (((is_open = 'N'::bpchar) OR ((open_time IS NOT NULL) AND (close_time > open_time))))
);


--
-- Name: appointment_status pk_appointment_status; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointment_status
    ADD CONSTRAINT pk_appointment_status PRIMARY KEY (status_id);


--
-- Name: appointment_status_history pk_appointment_status_history; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointment_status_history
    ADD CONSTRAINT pk_appointment_status_history PRIMARY KEY (history_id);


--
-- Name: appointments pk_appointments; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointments
    ADD CONSTRAINT pk_appointments PRIMARY KEY (appointment_id);


--
-- Name: audit_log pk_audit_log; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_log
    ADD CONSTRAINT pk_audit_log PRIMARY KEY (audit_id);


--
-- Name: clinic_closures pk_clinic_closures; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.clinic_closures
    ADD CONSTRAINT pk_clinic_closures PRIMARY KEY (closure_id);


--
-- Name: customers pk_customers; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT pk_customers PRIMARY KEY (customer_id);


--
-- Name: dim_date pk_dim_date; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dim_date
    ADD CONSTRAINT pk_dim_date PRIMARY KEY (date_key);


--
-- Name: expense_categories pk_expense_categories; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expense_categories
    ADD CONSTRAINT pk_expense_categories PRIMARY KEY (expense_category_id);


--
-- Name: expenses pk_expenses; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expenses
    ADD CONSTRAINT pk_expenses PRIMARY KEY (expense_id);


--
-- Name: image_uploads pk_image_uploads; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.image_uploads
    ADD CONSTRAINT pk_image_uploads PRIMARY KEY (image_id);


--
-- Name: medical_history pk_medical_history; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.medical_history
    ADD CONSTRAINT pk_medical_history PRIMARY KEY (record_id);


--
-- Name: ml_classifications pk_ml_classifications; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ml_classifications
    ADD CONSTRAINT pk_ml_classifications PRIMARY KEY (classification_id);


--
-- Name: payments pk_payments; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT pk_payments PRIMARY KEY (payment_id);


--
-- Name: roles pk_roles; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.roles
    ADD CONSTRAINT pk_roles PRIMARY KEY (role_id);


--
-- Name: service_price_history pk_service_price_history; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_price_history
    ADD CONSTRAINT pk_service_price_history PRIMARY KEY (price_id);


--
-- Name: services pk_services; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.services
    ADD CONSTRAINT pk_services PRIMARY KEY (service_id);


--
-- Name: staff pk_staff; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff
    ADD CONSTRAINT pk_staff PRIMARY KEY (staff_id);


--
-- Name: system_settings pk_system_settings; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_settings
    ADD CONSTRAINT pk_system_settings PRIMARY KEY (setting_key);


--
-- Name: users pk_users; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT pk_users PRIMARY KEY (user_id);


--
-- Name: website_interactions pk_website_interactions; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.website_interactions
    ADD CONSTRAINT pk_website_interactions PRIMARY KEY (interaction_id);


--
-- Name: working_hours pk_working_hours; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.working_hours
    ADD CONSTRAINT pk_working_hours PRIMARY KEY (day_of_week);


--
-- Name: appointment_status uq_appointment_status_status_name; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointment_status
    ADD CONSTRAINT uq_appointment_status_status_name UNIQUE (status_name);


--
-- Name: appointments uq_appointments_booking_reference; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointments
    ADD CONSTRAINT uq_appointments_booking_reference UNIQUE (booking_reference);


--
-- Name: appointments uq_appointments_staff_id_appointment_date_appointment_time; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointments
    ADD CONSTRAINT uq_appointments_staff_id_appointment_date_appointment_time UNIQUE (staff_id, appointment_date, appointment_time);


--
-- Name: clinic_closures uq_clinic_closures_closure_date; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.clinic_closures
    ADD CONSTRAINT uq_clinic_closures_closure_date UNIQUE (closure_date);


--
-- Name: customers uq_customers_email; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT uq_customers_email UNIQUE (email);


--
-- Name: customers uq_customers_user_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT uq_customers_user_id UNIQUE (user_id);


--
-- Name: dim_date uq_dim_date_full_date; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dim_date
    ADD CONSTRAINT uq_dim_date_full_date UNIQUE (full_date);


--
-- Name: expense_categories uq_expense_categories_category_name; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expense_categories
    ADD CONSTRAINT uq_expense_categories_category_name UNIQUE (category_name);


--
-- Name: ml_classifications uq_ml_classifications_image_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ml_classifications
    ADD CONSTRAINT uq_ml_classifications_image_id UNIQUE (image_id);


--
-- Name: roles uq_roles_role_name; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.roles
    ADD CONSTRAINT uq_roles_role_name UNIQUE (role_name);


--
-- Name: services uq_services_service_name; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.services
    ADD CONSTRAINT uq_services_service_name UNIQUE (service_name);


--
-- Name: staff uq_staff_user_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff
    ADD CONSTRAINT uq_staff_user_id UNIQUE (user_id);


--
-- Name: users uq_users_email; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT uq_users_email UNIQUE (email);


--
-- Name: users uq_users_username; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT uq_users_username UNIQUE (username);


--
-- Name: ix_appt_customer; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_appt_customer ON public.appointments USING btree (customer_id);


--
-- Name: ix_appt_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_appt_date ON public.appointments USING btree (appointment_date);


--
-- Name: ix_appt_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_appt_status ON public.appointments USING btree (status_id);


--
-- Name: ix_exp_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_exp_date ON public.expenses USING btree (expense_date);


--
-- Name: ix_hist_appt; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_hist_appt ON public.appointment_status_history USING btree (appointment_id);


--
-- Name: ix_pay_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_pay_date ON public.payments USING btree (payment_date);


--
-- Name: ix_pay_validated; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_pay_validated ON public.payments USING btree (is_validated);


--
-- Name: ix_web_datetime; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_web_datetime ON public.website_interactions USING btree (interaction_datetime);


--
-- Name: appointment_status_history fk_appointment_status_history_appointment_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointment_status_history
    ADD CONSTRAINT fk_appointment_status_history_appointment_id FOREIGN KEY (appointment_id) REFERENCES public.appointments(appointment_id);


--
-- Name: appointment_status_history fk_appointment_status_history_changed_by_user_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointment_status_history
    ADD CONSTRAINT fk_appointment_status_history_changed_by_user_id FOREIGN KEY (changed_by_user_id) REFERENCES public.users(user_id);


--
-- Name: appointment_status_history fk_appointment_status_history_status_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointment_status_history
    ADD CONSTRAINT fk_appointment_status_history_status_id FOREIGN KEY (status_id) REFERENCES public.appointment_status(status_id);


--
-- Name: appointments fk_appointments_classification_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointments
    ADD CONSTRAINT fk_appointments_classification_id FOREIGN KEY (classification_id) REFERENCES public.ml_classifications(classification_id);


--
-- Name: appointments fk_appointments_customer_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointments
    ADD CONSTRAINT fk_appointments_customer_id FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- Name: appointments fk_appointments_rescheduled_from_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointments
    ADD CONSTRAINT fk_appointments_rescheduled_from_id FOREIGN KEY (rescheduled_from_id) REFERENCES public.appointments(appointment_id);


--
-- Name: appointments fk_appointments_service_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointments
    ADD CONSTRAINT fk_appointments_service_id FOREIGN KEY (service_id) REFERENCES public.services(service_id);


--
-- Name: appointments fk_appointments_staff_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointments
    ADD CONSTRAINT fk_appointments_staff_id FOREIGN KEY (staff_id) REFERENCES public.staff(staff_id);


--
-- Name: appointments fk_appointments_status_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointments
    ADD CONSTRAINT fk_appointments_status_id FOREIGN KEY (status_id) REFERENCES public.appointment_status(status_id);


--
-- Name: audit_log fk_audit_log_user_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_log
    ADD CONSTRAINT fk_audit_log_user_id FOREIGN KEY (user_id) REFERENCES public.users(user_id);


--
-- Name: customers fk_customers_user_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT fk_customers_user_id FOREIGN KEY (user_id) REFERENCES public.users(user_id);


--
-- Name: expenses fk_expenses_expense_category_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expenses
    ADD CONSTRAINT fk_expenses_expense_category_id FOREIGN KEY (expense_category_id) REFERENCES public.expense_categories(expense_category_id);


--
-- Name: image_uploads fk_image_uploads_customer_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.image_uploads
    ADD CONSTRAINT fk_image_uploads_customer_id FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- Name: medical_history fk_medical_history_customer_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.medical_history
    ADD CONSTRAINT fk_medical_history_customer_id FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- Name: medical_history fk_medical_history_recorded_by_staff_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.medical_history
    ADD CONSTRAINT fk_medical_history_recorded_by_staff_id FOREIGN KEY (recorded_by_staff_id) REFERENCES public.staff(staff_id);


--
-- Name: ml_classifications fk_ml_classifications_image_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ml_classifications
    ADD CONSTRAINT fk_ml_classifications_image_id FOREIGN KEY (image_id) REFERENCES public.image_uploads(image_id);


--
-- Name: payments fk_payments_appointment_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT fk_payments_appointment_id FOREIGN KEY (appointment_id) REFERENCES public.appointments(appointment_id);


--
-- Name: payments fk_payments_customer_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT fk_payments_customer_id FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- Name: service_price_history fk_service_price_history_service_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_price_history
    ADD CONSTRAINT fk_service_price_history_service_id FOREIGN KEY (service_id) REFERENCES public.services(service_id);


--
-- Name: staff fk_staff_user_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff
    ADD CONSTRAINT fk_staff_user_id FOREIGN KEY (user_id) REFERENCES public.users(user_id);


--
-- Name: users fk_users_role_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT fk_users_role_id FOREIGN KEY (role_id) REFERENCES public.roles(role_id);


--
-- Name: website_interactions fk_website_interactions_appointment_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.website_interactions
    ADD CONSTRAINT fk_website_interactions_appointment_id FOREIGN KEY (appointment_id) REFERENCES public.appointments(appointment_id);


--
-- Name: website_interactions fk_website_interactions_classification_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.website_interactions
    ADD CONSTRAINT fk_website_interactions_classification_id FOREIGN KEY (classification_id) REFERENCES public.ml_classifications(classification_id);


--
-- Name: website_interactions fk_website_interactions_customer_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.website_interactions
    ADD CONSTRAINT fk_website_interactions_customer_id FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- Name: website_interactions fk_website_interactions_service_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.website_interactions
    ADD CONSTRAINT fk_website_interactions_service_id FOREIGN KEY (service_id) REFERENCES public.services(service_id);


--
-- PostgreSQL database dump complete
--

\unrestrict UyPE0WhxFU3M7WcYk3SAGskfq1JdM3dVGkcmhIouuI49OydQAfEDYIIITh2xE0n

